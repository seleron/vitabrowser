#!/usr/bin/env python3
"""Symbolise an sprof sample file (tools/vita-sim/sprof.c).

Usage: sprof-sym.py SAMPLES BINARY
Writes SAMPLES.pkl: a list of (stamp_us, tid, [function names, leaf
first]). The first two names are the profiler's handler and the signal
trampoline; the interrupted function is the third. Functions of the PIE
binary come from addr2line (return address - 1, the call site); others
are named by their library."""
import sys, subprocess, pickle, bisect
samples_path, binary = sys.argv[1], sys.argv[2]
maps = []
for l in open(samples_path + '.maps'):
    p = l.split()
    if len(p) < 6: continue
    a, b = (int(x, 16) for x in p[0].split('-'))
    maps.append((a, b, int(p[2], 16), p[5]))
maps.sort()
starts = [m[0] for m in maps]
samples = []
addrs = set()
for l in open(samples_path):
    p = l.split()
    st, tid, fr = int(p[0]), int(p[1]), [int(x, 16) for x in p[2:]]
    samples.append((st, tid, fr))
    addrs.update(fr)
def where(a):
    i = bisect.bisect_right(starts, a) - 1
    if i >= 0 and maps[i][0] <= a < maps[i][1]:
        return maps[i]
    return None
binbase = min(m[0] - m[2] for m in maps if m[3].endswith(binary.split('/')[-1]))
own = sorted(a for a in addrs if (w := where(a)) and w[3].endswith(binary.split('/')[-1]))
names = {}
if own:
    # return addresses point after the call: -1 lands inside the caller's line
    inp = '\n'.join(hex(a - binbase - 1) for a in own)
    out = subprocess.run(['addr2line', '-f', '-e', binary], input=inp, capture_output=True, text=True).stdout.split('\n')
    for i, a in enumerate(own):
        names[a] = out[2 * i]
for a in addrs:
    if a not in names:
        w = where(a)
        names[a] = '[' + (w[3].split('/')[-1] if w else '?') + ']'
res = [(st, tid, [names[a] for a in fr]) for st, tid, fr in samples]
pickle.dump(res, open(samples_path + '.pkl', 'wb'))
print(len(res), 'samples')
