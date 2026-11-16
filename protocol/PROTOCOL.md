# Remote Stats wire format v2

One server-to-client **1024-byte frame** every 2000 ms by default. No client requests,
JSON, HTTP/2, generated runtime, compression, heap objects, or variable-size fields
on the wire. All integers are **unsigned little-endian**, encoded byte-by-byte;
this is not a dumped C struct. A connection is a byte stream: consumers must buffer
partial reads, split coalesced frames, validate header/version/size, and reconnect
on malformed data. SSH supplies encryption, host verification, authentication,
and integrity. The collector only binds IPv4 loopback, port 47391.

## Header (384 bytes)

| Offset | Type | Meaning |
|---:|---|---|
| 0 | char[4] | `RST1` |
| 4 | u16 | Protocol version: 2 (Mac client also reads v1) |
| 6 | u16 | Frame size: 1024 |
| 8 | u64 | Sequence, resets when server restarts |
| 16 | u64 | Unix time, milliseconds |
| 24 | u32 | Sampling interval, milliseconds |
| 28 | u32 | Online logical CPU count |
| 32 | u32 | CPU percent × 1000, all CPUs normalized to 100% |
| 36 | u32 | Number of readable processes |
| 40,48 | u64 each | MemTotal, MemAvailable, bytes |
| 56,64 | u64 each | SwapTotal, SwapFree, bytes |
| 72,80 | u64 each | Physical NIC RX, TX bytes/sec |
| 88,96 | u64 each | Physical block-device read, write bytes/sec |
| 104,112 | u64 each | Root filesystem total, available bytes |
| 120 | u64 | Uptime, seconds |
| 128,132,136 | u32 each | 1/5/15 minute load × 1000 |
| 140 | u32 | Flags: bit 0 means interval deltas are ready |
| 144 | u64 | Collector wall duration, microseconds |
| 152 | char[64] | NUL-padded hostname (max 63 bytes) |
| 216 | u16[64] | Bits 0–13: logical CPU percent × 100; bits 14–15: class (0 unknown, 1 P, 2 E, 3 offline). Slots correspond to Linux CPU IDs 0–63 |
| 344 | u32 | Highest encoded CPU ID + 1, max 64; offline holes have class 3 |
| 348,352 | u32 each | User, system CPU percent × 1000 |
| 356,364,372 | u64 each | MemFree, Cached, Buffers bytes |
| 380,382 | u16 each | P-core and E-core physical counts among encoded CPUs; 0 if unknown |

## Process slots (640 bytes)

Offsets 384–703: top five by interval CPU; offsets 704–1023: top five by RSS.
Each 64-byte slot contains:

| Relative offset | Type | Meaning |
|---:|---|---|
| 0 | u32 | PID (0 indicates an unused slot) |
| 4 | u32 | CPU percent × 1000; 100% = one logical CPU |
| 8 | u64 | Resident memory bytes (RSS) |
| 16 | u64 | Process start time in boot ticks, protects against PID reuse |
| 24 | char[40] | NUL-padded process comm, max 39 bytes |

Process names come from `/proc/PID/stat`, not full command lines (which can expose
secrets). A process absent from the previous sample has CPU=0 until its next sample.
The first frame after an idle period is a warmup sample (flag 0).

## Metrics and bounds

- CPU uses `/proc/stat` deltas; excludes idle and I/O wait from busy time and does
  not double-count guest ticks. Per-process CPU uses utime+stime with USER_HZ and
  monotonic elapsed time. PID and start time must both match the previous sample.
- Memory used = MemTotal − MemAvailable. Page cache and buffers overlap available;
  they are informative values, not additive slices. RSS can double-count shared pages.
- Network includes NICs with a `/sys/class/net/NAME/device` entry, excluding bridge,
  loopback, veth, VPN duplication. Pure virtual-only hosts may show zero NIC traffic.
- Disk includes whole physical devices in `/sys/block`, skipping partitions, loop,
  ram, device-mapper and md aggregates to avoid double counting.
- Root capacity is refreshed at most once per 30 seconds; no recursive directory scans.
- At most eight clients. Shared samples, O(processes × log(processes)) CPU bookkeeping,
  O(processes × K) top selection, reusable process buffers. No threads/subprocesses in
  the collector, no sampling with no clients. Slow readers are disconnected rather
  than blocking sampling; clients reconnect automatically.
- 1024 bytes / 2 sec = 512 bytes/sec application payload per client. SSH adds overhead.
  No claim is made that a custom wire format alone improves overall CPU materially;
  `/proc` traversal and refresh frequency dominate. This deliberately chooses a
  smaller implementation over FlatBuffers/gRPC for one bounded message type.

Linux source semantics: https://www.kernel.org/doc/html/latest/filesystems/proc.html

## Hybrid topology (v2)

The server caches `/sys/bus/event_source/devices/cpu_core/cpus` (P threads) and
`cpu_atom/cpus` (E threads) at startup. Physical cores are deduplicated by package
ID and core ID from CPU topology sysfs. These kernel-reported classes are used
instead of CPU numbering assumptions, SMT or clock-rate heuristics. Restart the
collector after changing the online CPU topology. Unknown systems remain neutral;
o P/E split is invented when metadata is unavailable.

P and E percentages are the arithmetic mean busy percentage of their respective
online logical CPUs. They are not percentages of total host capacity, and do not
sum to total CPU. The total remains the aggregate `/proc/stat` utilization over all
logical CPUs. P-core Hyper-Threading siblings are displayed as separate bars.
CPU numbering and physical core counts are discovered from the host rather than
assumed from the processor model.

V1 clients must be upgraded before the V2 server; they reject version 2 rather
than misinterpreting tagged CPU values. The updated client accepts both versions.
The frame is still exactly 1024 bytes and does not add collection-time sysfs reads.
Kernel hybrid documentation: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/perf/Documentation/intel-hybrid.txt
