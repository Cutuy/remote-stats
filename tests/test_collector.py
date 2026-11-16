"""Linux integration tests: real procfs, bounded streams, reconnect, load accuracy."""
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024

def frame(sock):
    data = bytearray()
    while len(data) < SIZE:
        chunk = sock.recv(SIZE-len(data))
        if not chunk:
            raise EOFError('truncated frame')
        data.extend(chunk)
    return bytes(data)

def u32(b, offset): return struct.unpack_from('<I', b, offset)[0]
def u64(b, offset): return struct.unpack_from('<Q', b, offset)[0]

@unittest.skipUnless(sys.platform.startswith('linux'), 'requires Linux procfs')
class CollectorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['make', 'server'], cwd=ROOT, check=True)
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            cls.port = s.getsockname()[1]
        cls.server = subprocess.Popen([str(ROOT/'bin/remote-stats-server'), '--port', str(cls.port), '--interval-ms', '500'], stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                s=socket.create_connection(('127.0.0.1', cls.port), timeout=.1)
                s.close()
                break
            except OSError:
                time.sleep(.01)
        else:
            raise RuntimeError('collector did not start')

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait(timeout=3)

    def connect(self):
        s=socket.create_connection(('127.0.0.1', self.port), timeout=3)
        s.settimeout(3)
        return s

    def test_frame_metrics_and_sorted_top_lists(self):
        with self.connect() as s:
            b=frame(s)
            while not u32(b,140)&1: b=frame(s)
            self.assertEqual(b[:4], b'RST1')
            self.assertEqual(struct.unpack_from('<HH',b,4),(2,SIZE))
            self.assertLessEqual(u32(b,32),100000)
            self.assertGreater(u32(b,28),0)
            self.assertGreater(u64(b,40),0)
            self.assertLessEqual(u64(b,48),u64(b,40))
            self.assertLessEqual(u32(b,344),64)
            self.assertLess(u64(b,144),500000)
            cpus=[u32(b,384+i*64+4) for i in range(5)]
            mem=[u64(b,704+i*64+8) for i in range(5)]
            self.assertEqual(cpus,sorted(cpus,reverse=True))
            self.assertEqual(mem,sorted(mem,reverse=True))
            self.assertGreater(mem[0],0)
            second=frame(s)
            self.assertGreater(u64(second,8),u64(b,8))
            self.assertGreater(u64(second,16),u64(b,16))

    def test_kernel_hybrid_topology(self):
        expected={}
        for pmu,kind in [('cpu_core',1),('cpu_atom',2)]:
            path=Path('/sys/bus/event_source/devices')/pmu/'cpus'
            if not path.exists(): continue
            for item in path.read_text().strip().split(','):
                ends=item.split('-');first=int(ends[0]);last=int(ends[-1])
                for cpu in range(first,last+1): expected[cpu]=kind
        physical={1:set(),2:set()}
        with self.connect() as sock:
            b=frame(sock)
        for cpu in range(u32(b,344)):
            raw=struct.unpack_from('<H',b,216+2*cpu)[0]
            kind=raw>>14
            self.assertLessEqual(raw&0x3fff,10000)
            if kind==3: continue  # Offline CPU ID, not a real zero-usage core.
            self.assertEqual(kind,expected.get(cpu,0))
            if kind in physical:
                topology=Path(f'/sys/devices/system/cpu/cpu{cpu}/topology')
                physical[kind].add(((topology/'physical_package_id').read_text().strip(),(topology/'core_id').read_text().strip()))
        self.assertEqual(struct.unpack_from('<HH',b,380),(len(physical[1]),len(physical[2])))

    def test_cpu_load_is_one_core_percent(self):
        busy=subprocess.Popen([sys.executable,'-c','while True: pass'])
        try:
            with self.connect() as s:
                found=[]
                for _ in range(7):
                    b=frame(s)
                    for i in range(5):
                        o=384+i*64
                        if u32(b,o)==busy.pid: found.append(u32(b,o+4)/1000)
                self.assertTrue(found, 'busy process should appear in top five')
                self.assertGreater(max(found),40, 'busy process should use a substantial fraction of one CPU')
                self.assertLess(max(found),150)
        finally:
            busy.terminate();busy.wait(timeout=3)

    def test_multiple_clients_share_samples_and_reconnect(self):
        with self.connect() as a, self.connect() as b:
            fa=frame(a);fb=frame(b)
            # New clients may receive a cached frame; match streams by sequence.
            while u64(fa,8)<u64(fb,8): fa=frame(a)
            while u64(fb,8)<u64(fa,8): fb=frame(b)
            self.assertEqual(fa,fb)
        time.sleep(.15)
        with self.connect() as s:
            self.assertEqual(len(frame(s)),SIZE)

    def test_no_clients_no_sampling(self):
        time.sleep(.7)  # Let the final client disconnect be observed.
        stat=Path(f'/proc/{self.server.pid}/stat')
        def ticks():
            fields=stat.read_text().rsplit(')',1)[1].split()
            return int(fields[11])+int(fields[12])
        before=ticks();time.sleep(1.2)
        self.assertLessEqual(ticks()-before,1)

    def test_invalid_arguments_rejected(self):
        for args in (['--interval-ms','0'], ['--port','99999'], ['--unknown']):
            p=subprocess.run([str(ROOT/'bin/remote-stats-server'),*args],capture_output=True)
            self.assertEqual(p.returncode,2)

if __name__=='__main__': unittest.main()
