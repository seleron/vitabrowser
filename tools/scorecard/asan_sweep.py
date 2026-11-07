#!/usr/bin/env python3
"""Load scorecard sites in an ASan simulator and report any ASan error.

Each load is exactly a scorecard load (scorecard.run_sim: same directory
layout, blocklist, settle 15000, quit -> full netsurf_exit teardown); only
the binary differs. Patches 395/396 (doc 10): the wpblog/oldreddit/mdn
crashes never reproduced under gdb but ASan caught them on every load.

usage: WORK=<WORK>/vitabrowser-work /usr/bin/python3 asan_sweep.py \\
           <asan-sim> <outdir> [--runs N] [--jobs N] [--only a,b] [--skip a,b]
Exit status 1 if any load reports an ASan error.
"""
import argparse, os, re, sys, concurrent.futures as cf

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ.setdefault("ASAN_OPTIONS", "detect_leaks=0:halt_on_error=1")
import scorecard as sc  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("sim")
ap.add_argument("out")
ap.add_argument("--runs", type=int, default=3)
ap.add_argument("--jobs", type=int, default=4)
ap.add_argument("--only", default="")
ap.add_argument("--skip", default="")
ap.add_argument("--sites", default=os.path.join(HERE, "sites.tsv"))
a = ap.parse_args()
sc.SIM = os.path.abspath(a.sim)
out = os.path.abspath(a.out)
only = set(filter(None, a.only.split(",")))
skip = set(filter(None, a.skip.split(",")))

sites, block = [], {}
for line in open(a.sites):
    if not line.strip() or line.startswith("#"):
        continue
    c = line.rstrip("\n").split("\t")
    name = c[1].strip()
    if (only and name not in only) or name in skip:
        continue
    sites.append((name, c[2].strip()))
    if len(c) > 3 and c[3].strip():
        block[name] = [h.strip().lower() for h in c[3].split(",") if h.strip()]

ERR = re.compile(r"ERROR: AddressSanitizer: ([\w-]+)")
FRAME = re.compile(r"#0 0x[0-9a-f]+ in (\S+) (\S+)")


def one(job):
    site, url, i, slot = job
    name = "%s-%d" % (site, i)
    if site in block:
        sc.BLOCK[name] = block[site]
    r = sc.run_sim(out, name, url, 50 + slot, 15000, 400)
    log = open(os.path.join(out, "sim", name, "out.log"),
               errors="replace").read()
    m = ERR.search(log)
    top = ""
    if m:
        f = FRAME.search(log[m.end():])
        top = "%s in %s (%s)" % (m.group(1), f.group(1) if f else "?",
                                 f.group(2) if f else "?")
    return name, r["rc"], r["state"], r["wall"], top


jobs = [(s, u, i, k % 40) for k, (i, (s, u)) in enumerate(
    (i, su) for i in range(a.runs) for su in sites)]
bad = 0
with cf.ThreadPoolExecutor(a.jobs) as ex:
    for name, rc, st, wall, top in ex.map(one, jobs):
        bad += bool(top)
        print("%-18s %-5s %-8s %6s  %s" % (name, rc, st, wall, top),
              flush=True)
print("%d loads, %d with an ASan error" % (len(jobs), bad))
sys.exit(1 if bad else 0)
