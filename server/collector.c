#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/statvfs.h>
#include <time.h>
#include <unistd.h>

/* Explicit little-endian wire encoding: no ABI structs, pointers or padding. */
enum { FRAME_SIZE=1024, TOP_K=5, MAX_CLIENTS=8, MAX_CORES=64 };
typedef struct { uint64_t total, idle; } CPU;
typedef struct { uint32_t pid, cpu; uint64_t ticks, start, rss; char name[40]; } Proc;
typedef struct {
    CPU cpus[MAX_CORES+1]; unsigned cpu_slots; Proc *procs; size_t count, cap;
    uint64_t rx, tx, rd, wr; double time;
} Sample;
static Sample previous, current;
static uint64_t sequence;
static long hz, pages;
static volatile sig_atomic_t running=1;
/* 0 unknown, 1 performance, 2 efficiency. No frequency/SMT guesses. */
static uint8_t core_kind[MAX_CORES];
static uint16_t physical_cores[3];
static void stop(int sig) { (void)sig; running=0; }
static double mono(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static void put16(uint8_t *b,int o,uint16_t n) { b[o]=n; b[o+1]=n>>8; }
static void put32(uint8_t *b,int o,uint32_t n) { for(int i=0;i<4;i++) b[o+i]=(uint8_t)(n>>(i*8)); }
static void put64(uint8_t *b,int o,uint64_t n) { for(int i=0;i<8;i++) b[o+i]=(uint8_t)(n>>(i*8)); }
static uint64_t delta(uint64_t a,uint64_t b) { return a>=b?a-b:0; }
static uint32_t usage(CPU a,CPU b) { uint64_t d=delta(a.total,b.total), idle=delta(a.idle,b.idle); return d?(uint32_t)(100000.0*(d-(idle>d?d:idle))/d):0; }
static FILE *openfile(const char *path) { return fopen(path,"re"); }
static void read_cpu_list(const char *path,uint8_t kind) {
    FILE *f=openfile(path); if(!f)return;
    char line[4096]; char *ok=fgets(line,sizeof line,f);fclose(f);if(!ok)return;
    char *p=line;
    while(*p) {
        while(*p==','||isspace((unsigned char)*p))p++;
        if(!*p)break;
        char *end;long first=strtol(p,&end,10);if(end==p||first<0)break;p=end;
        long last=first;
        if(*p=='-'){last=strtol(p+1,&end,10);if(end==p+1||last<first)break;p=end;}
        if(first<MAX_CORES)for(long id=first;id<=last&&id<MAX_CORES;id++)core_kind[id]=kind;
    }
}
static int read_topology_value(unsigned cpu,const char *name) {
    char path[180];snprintf(path,sizeof path,"/sys/devices/system/cpu/cpu%u/topology/%s",cpu,name);
    FILE *f=openfile(path);int value=-1;if(f){if(fscanf(f,"%d",&value)!=1)value=-1;fclose(f);}return value;
}
static void read_topology(void) {
    /* Kernel hybrid PMU CPU lists are authoritative and don't require perf access. */
    read_cpu_list("/sys/bus/event_source/devices/cpu_core/cpus",1);
    read_cpu_list("/sys/bus/event_source/devices/cpu_atom/cpus",2);
    int packages[MAX_CORES],ids[MAX_CORES];
    for(unsigned cpu=0;cpu<MAX_CORES;cpu++) {
        packages[cpu]=read_topology_value(cpu,"physical_package_id");
        ids[cpu]=read_topology_value(cpu,"core_id");
        if(!core_kind[cpu]||packages[cpu]<0||ids[cpu]<0)continue;
        int duplicate=0;
        for(unsigned j=0;j<cpu;j++)if(core_kind[j]==core_kind[cpu]&&packages[j]==packages[cpu]&&ids[j]==ids[cpu]){duplicate=1;break;}
        if(!duplicate)physical_cores[core_kind[cpu]]++;
    }
}
static int by_pid(const void *a,const void *b) { uint32_t x=((const Proc*)a)->pid,y=((const Proc*)b)->pid; return (x>y)-(x<y); }
static void read_processes(Sample *s) {
    DIR *dir=opendir("/proc"); if(!dir) return;
    struct dirent *e; s->count=0;
    while((e=readdir(dir))) {
        if(!isdigit((unsigned char)e->d_name[0])) continue;
        char path[300], line[4096]; snprintf(path,sizeof path,"/proc/%s/stat",e->d_name);
        FILE *f=openfile(path); if(!f) continue;
        char *ok=fgets(line,sizeof line,f); fclose(f); if(!ok) continue;
        char *left=strchr(line,'('),*right=strrchr(line,')'); if(!left||!right||right<=left) continue;
        Proc p={.pid=(uint32_t)strtoul(e->d_name,NULL,10)};
        size_t len=(size_t)(right-left-1); if(len>39)len=39;
        memcpy(p.name,left+1,len);
        for(size_t i=0;i<len;i++) if((unsigned char)p.name[i]<32||p.name[i]==127)p.name[i]='?';
        /* Fields 3..24: comm can contain spaces and closing parentheses. */
        char *save=NULL,*token=strtok_r(right+2," ",&save); long long rss=0;
        for(int field=3;token&&field<=24;field++,token=strtok_r(NULL," ",&save)) {
            if(field==14||field==15)p.ticks+=strtoull(token,NULL,10);
            if(field==22)p.start=strtoull(token,NULL,10);
            if(field==24)rss=strtoll(token,NULL,10);
        }
        p.rss=rss>0?(uint64_t)rss*(uint64_t)pages:0;
        if(s->count==s->cap) {
            size_t cap=s->cap?s->cap*2:1024; Proc *buf=realloc(s->procs,cap*sizeof *buf);
            if(!buf) { closedir(dir); perror("process buffer"); exit(1); }
            s->procs=buf;s->cap=cap;
        }
        s->procs[s->count++]=p;
    }
    closedir(dir);
    qsort(s->procs,s->count,sizeof(Proc),by_pid);
    double elapsed=s->time-previous.time;
    if(previous.time>0&&previous.count>0&&elapsed>0) for(size_t i=0;i<s->count;i++) {
        Proc *p=&s->procs[i]; Proc *old=bsearch(p,previous.procs,previous.count,sizeof(Proc),by_pid);
        if(old&&old->start==p->start) p->cpu=(uint32_t)fmin(UINT32_MAX,100000.0*delta(p->ticks,old->ticks)/hz/elapsed);
    }
}
static void read_cpus(Sample *s,uint32_t *count,uint32_t *user,uint32_t *system) {
    FILE *f=openfile("/proc/stat"); if(!f)return;
    char line[512]; unsigned n=0;
    while(fgets(line,sizeof line,f)) {
        if(strncmp(line,"cpu",3))break;
        char label[16]; unsigned long long v[8]={0};
        if(sscanf(line,"%15s %llu %llu %llu %llu %llu %llu %llu %llu",label,&v[0],&v[1],&v[2],&v[3],&v[4],&v[5],&v[6],&v[7])<5)continue;
        int idx=label[3]?atoi(label+3)+1:0; if(idx>MAX_CORES){n++;continue;}
        CPU c={0};for(int j=0;j<8;j++)c.total+=v[j];c.idle=v[3]+v[4]; s->cpus[idx]=c;
        if(idx){n++;if((unsigned)idx>s->cpu_slots)s->cpu_slots=(unsigned)idx;}
        else {
            /* Guest ticks are already in user/nice; don't double count them. */
            static uint64_t old_user,old_sys;
            uint64_t u=v[0]+v[1],sy=v[2]+v[5]+v[6],d=delta(c.total,previous.cpus[0].total);
            if(previous.time&&d){*user=(uint32_t)(100000.0*delta(u,old_user)/d);*system=(uint32_t)(100000.0*delta(sy,old_sys)/d);}
            old_user=u;old_sys=sy;
        }
    }
    fclose(f);*count=n;
}
static void read_io(Sample *s) {
    FILE *f=openfile("/proc/net/dev"); char line[1024];
    if(f){while(fgets(line,sizeof line,f)){
        char name[64], path[150]; unsigned long long rx,tx;
        if(sscanf(line," %63[^:]: %llu %*u %*u %*u %*u %*u %*u %*u %llu",name,&rx,&tx)!=3)continue;
        snprintf(path,sizeof path,"/sys/class/net/%s/device",name);
        if(access(path,F_OK))continue; /* Physical NICs only, avoids bridge/VPN double-counting. */
        s->rx+=rx;s->tx+=tx;
    }fclose(f);}
    f=openfile("/proc/diskstats");
    if(f){while(fgets(line,sizeof line,f)){
        char name[64],path[150];unsigned long long rd,wr;
        if(sscanf(line,"%*u %*u %63s %*u %*u %llu %*u %*u %*u %llu",name,&rd,&wr)!=3)continue;
        snprintf(path,sizeof path,"/sys/block/%s",name);
        if(access(path,F_OK)||!strncmp(name,"loop",4)||!strncmp(name,"ram",3)||!strncmp(name,"dm-",3)||!strncmp(name,"md",2))continue;
        s->rd+=rd*512;s->wr+=wr*512;
    }fclose(f);}
}
static void insert_top(Proc **top,Proc *p,int cpu) {
    for(int i=0;i<TOP_K;i++)if(!top[i]||(cpu?p->cpu>top[i]->cpu:p->rss>top[i]->rss)){
        for(int j=TOP_K-1;j>i;j--) { top[j]=top[j-1]; }
        top[i]=p;break;
    }
}
static void collect(uint8_t *b,uint32_t interval) {
    double began=mono();
    Sample temp=previous;previous=current;current=temp;
    /* Keep reusable process buffers, clear scalar values. */
    Proc *buf=current.procs;size_t cap=current.cap;memset(&current,0,sizeof current);current.procs=buf;current.cap=cap;current.time=began;
    memset(b,0,FRAME_SIZE);memcpy(b,"RST1",4);put16(b,4,2);put16(b,6,FRAME_SIZE);
    put64(b,8,++sequence);struct timespec wall;clock_gettime(CLOCK_REALTIME,&wall);put64(b,16,(uint64_t)wall.tv_sec*1000+wall.tv_nsec/1000000);
    put32(b,24,interval);
    uint32_t cores=0,user=0,system=0;read_cpus(&current,&cores,&user,&system);
    put32(b,28,cores);put32(b,32,previous.time?usage(current.cpus[0],previous.cpus[0]):0);
    FILE *f=openfile("/proc/meminfo");char line[256];uint64_t total=0,available=0,swap=0,swapfree=0,free_mem=0,cached=0,buffers=0;
    if(f){while(fgets(line,sizeof line,f)){
        char key[64];unsigned long long kb;if(sscanf(line,"%63s %llu",key,&kb)!=2)continue;uint64_t v=kb*1024;
        if(!strcmp(key,"MemTotal:"))total=v;else if(!strcmp(key,"MemAvailable:"))available=v;
        else if(!strcmp(key,"SwapTotal:"))swap=v;else if(!strcmp(key,"SwapFree:"))swapfree=v;
        else if(!strcmp(key,"MemFree:"))free_mem=v;else if(!strcmp(key,"Cached:"))cached=v;else if(!strcmp(key,"Buffers:"))buffers=v;
    }fclose(f);}
    put64(b,40,total);put64(b,48,available);put64(b,56,swap);put64(b,64,swapfree);
    read_io(&current);double elapsed=began-previous.time;
    if(previous.time&&elapsed>0){
        put64(b,72,(uint64_t)(delta(current.rx,previous.rx)/elapsed));put64(b,80,(uint64_t)(delta(current.tx,previous.tx)/elapsed));
        put64(b,88,(uint64_t)(delta(current.rd,previous.rd)/elapsed));put64(b,96,(uint64_t)(delta(current.wr,previous.wr)/elapsed));
    }
    static double fs_checked;static uint64_t fs_total,fs_avail;
    if(!fs_checked||began-fs_checked>=30){struct statvfs fs;if(!statvfs("/",&fs)){fs_total=(uint64_t)fs.f_blocks*fs.f_frsize;fs_avail=(uint64_t)fs.f_bavail*fs.f_frsize;}fs_checked=began;}
    put64(b,104,fs_total);put64(b,112,fs_avail);
    double uptime=0;f=openfile("/proc/uptime");if(f){if(fscanf(f,"%lf",&uptime)!=1)uptime=0;fclose(f);}put64(b,120,(uint64_t)uptime);
    double load[3]={0};getloadavg(load,3);for(int i=0;i<3;i++)put32(b,128+4*i,(uint32_t)(load[i]*1000));
    put32(b,140,previous.time?1:0);gethostname((char*)b+152,63);
    unsigned encoded=current.cpu_slots;put32(b,344,encoded);
    for(unsigned i=0;i<encoded;i++) {
        uint16_t value=previous.time&&previous.cpus[i+1].total?(uint16_t)(usage(current.cpus[i+1],previous.cpus[i+1])/10):0;
        uint16_t kind=current.cpus[i+1].total?core_kind[i]:3; /* 3 = offline hole */
        put16(b,216+2*i,(uint16_t)(value|(kind<<14)));
    }
    put16(b,380,physical_cores[1]);put16(b,382,physical_cores[2]);
    put32(b,348,user);put32(b,352,system);put64(b,356,free_mem);put64(b,364,cached);put64(b,372,buffers);
    read_processes(&current);put32(b,36,(uint32_t)current.count);
    Proc *cpu[TOP_K]={0},*mem[TOP_K]={0};
    for(size_t i=0;i<current.count;i++){insert_top(cpu,&current.procs[i],1);insert_top(mem,&current.procs[i],0);}
    for(int i=0;i<2*TOP_K;i++){Proc *p=i<TOP_K?cpu[i]:mem[i-TOP_K];if(!p)continue;int o=384+i*64;put32(b,o,p->pid);put32(b,o+4,p->cpu);put64(b,o+8,p->rss);put64(b,o+16,p->start);memcpy(b+o+24,p->name,40);}
    put64(b,144,(uint64_t)((mono()-began)*1e6));
}
static void send_frame(int *fd,const uint8_t *b) {
    if(*fd<0)return;
    ssize_t sent=send(*fd,b,FRAME_SIZE,MSG_NOSIGNAL|MSG_DONTWAIT);
    /* A slow reader must never delay sampling; reconnect on a short write. */
    if(sent!=FRAME_SIZE){close(*fd);*fd=-1;}
}
int main(int argc,char **argv) {
    int port=47391;uint32_t interval=2000;int once=0;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"--once"))once=1;
        else if(!strcmp(argv[i],"--port")&&i+1<argc)port=atoi(argv[++i]);
        else if(!strcmp(argv[i],"--interval-ms")&&i+1<argc)interval=(uint32_t)atoi(argv[++i]);
        else {fprintf(stderr,"Usage: %s [--port 47391] [--interval-ms 2000] [--once]\n",argv[0]);return 2;}
    }
    if(port<1||port>65535||interval<500||interval>60000){fprintf(stderr,"Invalid port or interval (500..60000ms)\n");return 2;}
    hz=sysconf(_SC_CLK_TCK);pages=sysconf(_SC_PAGESIZE);if(hz<=0||pages<=0)return 1;
    read_topology();
    signal(SIGINT,stop);signal(SIGTERM,stop);signal(SIGPIPE,SIG_IGN);
    uint8_t frame[FRAME_SIZE];
    if(once){collect(frame,interval);struct timespec t={interval/1000,(interval%1000)*1000000};nanosleep(&t,NULL);collect(frame,interval);return fwrite(frame,1,FRAME_SIZE,stdout)==FRAME_SIZE?0:1;}
    int listener=socket(AF_INET,SOCK_STREAM|SOCK_CLOEXEC|SOCK_NONBLOCK,0);int yes=1;
    if(listener<0){perror("socket");return 1;}setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof yes);
    struct sockaddr_in addr={.sin_family=AF_INET,.sin_port=htons((uint16_t)port),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if(bind(listener,(struct sockaddr*)&addr,sizeof addr)||listen(listener,8)){perror("listen");return 1;}
    fprintf(stderr,"remote-stats listening on 127.0.0.1:%d, %ums, %d-byte frames\n",port,interval,FRAME_SIZE);
    struct pollfd fds[MAX_CLIENTS+1];fds[0]=(struct pollfd){listener,POLLIN,0};for(int i=1;i<=MAX_CLIENTS;i++)fds[i]=(struct pollfd){-1,POLLIN,0};
    double next=0;int was_active=0;
    while(running){
        int active=0;for(int i=1;i<=MAX_CLIENTS;i++)if(fds[i].fd>=0)active++;
        if(!active&&was_active){current.time=0;previous.time=0;was_active=0;next=0;}
        int timeout=active?(int)fmax(0,(next-mono())*1000):-1;
        int result=poll(fds,MAX_CLIENTS+1,timeout);if(result<0){if(errno==EINTR)continue;perror("poll");break;}
        if(fds[0].revents&POLLIN){
            int fd;while((fd=accept4(listener,NULL,NULL,SOCK_CLOEXEC|SOCK_NONBLOCK))>=0){
                setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&yes,sizeof yes);int slot=0;
                for(int i=1;i<=MAX_CLIENTS;i++)if(fds[i].fd<0){slot=i;break;}
                if(slot){fds[slot].fd=fd;if(active&&sequence)send_frame(&fds[slot].fd,frame);active++;}else close(fd);
            }
        }
        for(int i=1;i<=MAX_CLIENTS;i++)if(fds[i].fd>=0&&fds[i].revents){
            char c;ssize_t n=recv(fds[i].fd,&c,1,MSG_DONTWAIT);
            if(n==0||(n<0&&errno!=EAGAIN&&errno!=EWOULDBLOCK)||(fds[i].revents&(POLLHUP|POLLERR|POLLNVAL))){close(fds[i].fd);fds[i].fd=-1;}
        }
        if(active&&mono()>=next){collect(frame,interval);for(int i=1;i<=MAX_CLIENTS;i++)send_frame(&fds[i].fd,frame);next=mono()+interval/1000.0;was_active=1;}
    }
    for(int i=0;i<=MAX_CLIENTS;i++)if(fds[i].fd>=0)close(fds[i].fd);
    free(previous.procs);free(current.procs);return 0;
}
