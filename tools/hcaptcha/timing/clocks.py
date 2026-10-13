#!/usr/bin/env python3
"""Clock readings from clock-probe.js (tools/hcaptcha/timing/README): per
file, how many performance.now() / Date.now() reads, how many
performance.now() values are exact tenths, and the first deltas.
Usage: clocks.py chromium.txt simulator.txt ..."""
import sys, re, collections
def load(p):
    vals=[]
    for l in open(p, errors='replace'):
        if not l.startswith('TMREC challenge'): continue
        vals += l.split()[2:]
    return vals
for p in sys.argv[1:]:
    v=load(p); P=[float(x[1:]) for x in v if x[0]=='p']; Dn=[int(x[1:]) for x in v if x[0]=='d']
    clean=sum(1 for x in P if repr(x)==repr(round(x,1)))
    d=[round(P[i+1]-P[i],4) for i in range(len(P)-1)]
    zero=sum(1 for x in d if x==0); small=sum(1 for x in d if 0<x<0.15)
    grid=collections.Counter(round((x*10)%1,6) for x in P)
    print(p, 'perf.now', len(P), 'Date.now', len(Dn), 'clean tenths %d/%d' % (clean,len(P)), 'zero deltas', zero, 'deltas<0.15ms', small)
    print('   first values', P[:8]); print('   deltas', d[:30])
