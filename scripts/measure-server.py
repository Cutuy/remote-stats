import json, socket, struct, time, os, statistics, subprocess
pid=int(subprocess.check_output(['systemctl','--user','show','remote-stats','-p','MainPID','--value']))
def stats():
    fields=open(f'/proc/{pid}/stat').read().rsplit(')',1)[1].split()
    return int(fields[11])+int(fields[12]), int(fields[21])*os.sysconf('SC_PAGE_SIZE')
s=socket.create_connection(('127.0.0.1',47391));s.settimeout(5)
def frame():
    b=b''
    while len(b)<1024:
        c=s.recv(1024-len(b))
        if not c: raise EOFError()
        b+=c
    return b
frame();before,rss=stats();start=time.monotonic();durations=[];count=0
while time.monotonic()-start<30:
    b=frame();count+=1;durations.append(struct.unpack_from('<Q',b,144)[0])
end,rss=stats();elapsed=time.monotonic()-start
print(json.dumps({'duration_seconds':round(elapsed,2),'frames':count,'collector_cpu_percent_one_core':round((end-before)/os.sysconf('SC_CLK_TCK')/elapsed*100,3),'collector_rss_bytes':rss,'sample_duration_median_us':statistics.median(durations),'sample_duration_max_us':max(durations),'payload_bytes_per_second':round(1024*count/elapsed,1)},indent=2))
