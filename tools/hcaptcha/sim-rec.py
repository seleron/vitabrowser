#!/usr/bin/env python3
"""Rebuild hsw-record.js's records from a simulator's engine log: lines
"MS [js] HSWREC <tag> : <event>", continued by "... HSWREC <tag> + <more>"
(the console keeps one line per call, at most ~2 KB).
Usage: sim-rec.py netsurf.log OUTDIR  -> OUTDIR/<tag>.rec"""
import os, re, sys

LINE = re.compile(r"^MS \[js\] HSWREC (\S+) ([:+]) ?(.*)$")
recs = {}
for raw in open(sys.argv[1], errors="replace"):
    m = LINE.match(raw.rstrip("\n"))
    if not m:
        continue
    tag, kind, text = m.groups()
    r = recs.setdefault(tag, [])
    if kind == "+" and r:
        r[-1] += text
    else:
        r.append(text)
os.makedirs(sys.argv[2], exist_ok=True)
for tag, lines in recs.items():
    with open(os.path.join(sys.argv[2], tag + ".rec"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("%s: %d events" % (tag, len(lines)))
