#!/usr/bin/env python3
"""Full-rebuild census over several loads per arm (doc 10, patch 435).

The census counts, per site load, the committed full rebuilds
(`LIFE BATCHCAUSE cause=...`, one per batch that fell back to the full
reconvert) and the local path's declines (`LIFE rebuild local: ...
declined (reason)`). One load per arm is not enough to judge a small
unit: the per-site count moves by 2-7 run to run on the live sites
(claude 11 vs 4 on the same binary in r145). This loads every site
LOADS times in every arm, interleaved (load 1 of every arm, then load 2,
...) so both arms meet the same network, and reports per site the counts
of each load and their mean, and per arm the total's mean and range.

Only the simulator side runs: no Chrome reference, no score.

Usage:
  tools/scorecard/census.py --out DIR --arm 434=/path/nsvita-sim \\
      --arm 435=/path/nsvita-sim [--only a,b] [--loads 3] [--jobs 4]
      [--settle 15000] [--timeout 240]
  tools/scorecard/census.py --out DIR --report     (re-read DIR's logs)

Each arm's binary is copied into DIR/bin/ first, so a rebuild during the
run cannot change an arm. Loads land in DIR/<arm>/L<n>/sim/<site>/.
Writes DIR/census.md and DIR/census.json.
"""

import argparse
import concurrent.futures
import json
import os
import queue
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import scorecard  # noqa: E402

CAUSE_RE = re.compile(r"LIFE BATCHCAUSE cause=(\w+)")
DECL_RE = re.compile(r"LIFE rebuild local: (?:([a-z ]+): )?declined \((.*?)\)"
                     r"(?: after \d+ elements)?(?: in \d+ us)?\s*$")
# a tag named in a reason ("an element's style changes, DIV") is detail:
# the reason groups without it
TAG_RE = re.compile(r", [A-Z][A-Z0-9-]*$")


def read_load(d):
    """Counts of one load directory (DIR/<arm>/L<n>/sim/<site>)."""
    r = {"batch": 0, "causes": {}, "declines": {}, "asserts": [],
         "state": "missing"}
    log = os.path.join(d, "ux0:data", "VitaBrowser", "netsurf.log")
    out = os.path.join(d, "out.log")
    if not os.path.isfile(log):
        return r
    for line in open(log, errors="replace"):
        m = CAUSE_RE.search(line)
        if m:
            r["batch"] += 1
            r["causes"][m.group(1)] = r["causes"].get(m.group(1), 0) + 1
            continue
        if "declined (" in line:
            m = DECL_RE.search(line.rstrip("\n"))
            if m:
                why = TAG_RE.sub("", m.group(2))
                if m.group(1):
                    why = m.group(1) + ": " + why
                r["declines"][why] = r["declines"].get(why, 0) + 1
    o = open(out, errors="replace").read() if os.path.isfile(out) else ""
    r["asserts"] = sorted(set(l.strip()[:160] for l in o.splitlines()
                              if "Assertion" in l or "Segmentation" in l))
    st = os.path.join(d, "state.json")
    if os.path.isfile(st):
        r["state"] = json.load(open(st)).get("state", "?")
    return r


def mean(v):
    return sum(v) / len(v) if v else 0.0


def report(out, arms, sites, loads):
    data = {}
    for arm in arms:
        data[arm] = {}
        for s in sites:
            data[arm][s] = [read_load(os.path.join(out, arm, "L%d" % n,
                                                   "sim", s))
                            for n in range(1, loads + 1)]
    lines = ["# Full-rebuild census, %d loads per arm" % loads, "",
             "Per site: BATCHCAUSE per load (mean). A load that did not "
             "finish loaded is marked (crash / timeout / missing).", "",
             "| site | " + " | ".join(arms) + " | Δ mean |",
             "|---|" + "---|" * (len(arms) + 1)]
    for s in sites:
        cells, means = [], []
        for arm in arms:
            ls = data[arm][s]
            v = [l["batch"] for l in ls]
            mark = ["" if l["state"] == "loaded" else "!" + l["state"]
                    for l in ls]
            cells.append("%s (%.1f)" % (" / ".join(
                "%d%s" % (n, m) for n, m in zip(v, mark)), mean(v)))
            means.append(mean(v))
        d = "%+.1f" % (means[-1] - means[0]) if len(means) > 1 else ""
        lines.append("| %s | %s | %s |" % (s, " | ".join(cells), d))
    tot = {}
    for arm in arms:
        per = [sum(data[arm][s][n]["batch"] for s in sites)
               for n in range(loads)]
        tot[arm] = per
    lines.append("| **total** | %s | %s |" % (" | ".join(
        "%s (**%.1f**)" % (" / ".join(str(x) for x in tot[a]), mean(tot[a]))
        for a in arms), "%+.1f" % (mean(tot[arms[-1]]) - mean(tot[arms[0]]))
        if len(arms) > 1 else ""))
    # causes and decline reasons: mean per load over all sites
    for key, title in (("causes", "BATCHCAUSE cause"),
                       ("declines", "local-path decline reason")):
        agg = {}
        for arm in arms:
            for s in sites:
                for l in data[arm][s]:
                    for k, n in l[key].items():
                        agg.setdefault(k, {}).setdefault(arm, 0)
                        agg[k][arm] += n
        rows = sorted(agg.items(), key=lambda kv: -max(kv[1].values()))
        lines += ["", "| %s (mean per load, all sites) | %s |" % (
            title, " | ".join(arms)), "|---|" + "---|" * len(arms)]
        for k, per in rows[:30]:
            lines.append("| %s | %s |" % (k.replace("|", "\\|"), " | ".join(
                "%.1f" % (per.get(a, 0) / loads) for a in arms)))
    bad = []
    for arm in arms:
        for s in sites:
            for n, l in enumerate(data[arm][s], 1):
                for a in l["asserts"]:
                    bad.append("- %s %s L%d: `%s`" % (arm, s, n, a))
                if l["state"] != "loaded":
                    bad.append("- %s %s L%d: %s" % (arm, s, n, l["state"]))
    lines += ["", "## Loads that crashed, asserted or did not load", ""]
    lines += bad or ["none"]
    with open(os.path.join(out, "census.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(out, "census.json"), "w") as f:
        json.dump({"arms": arms, "sites": sites, "loads": loads,
                   "data": data}, f, indent=1)
    print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--arm", action="append", default=[],
                    help="NAME=PATH to an nsvita-sim binary (repeat)")
    ap.add_argument("--sites", default=os.path.join(HERE, "sites.tsv"))
    ap.add_argument("--only", default="")
    ap.add_argument("--loads", type=int, default=3)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--settle", type=int, default=15000)
    ap.add_argument("--timeout", type=int, default=240)
    ap.add_argument("--report", action="store_true",
                    help="only re-read an existing run's logs")
    a = ap.parse_args()

    sites = []
    for line in open(a.sites):
        if line.strip() and not line.startswith("#"):
            cols = line.rstrip("\n").split("\t")
            name, url = cols[1].strip(), cols[2].strip()
            sites.append((name, url))
            if len(cols) > 3 and cols[3].strip():
                scorecard.BLOCK[name] = [h.strip().lower() for h in
                                         cols[3].split(",") if h.strip()]
    if a.only:
        keep = a.only.split(",")
        sites = [s for s in sites if s[0] in keep]
    names = [s[0] for s in sites]
    a.out = os.path.abspath(a.out)	# the simulator runs in each load's dir
    os.makedirs(a.out, exist_ok=True)
    meta = os.path.join(a.out, "arms.json")

    if a.report:
        m = json.load(open(meta))
        report(a.out, m["arms"], m.get("sites", names), m["loads"])
        return 0

    if not a.arm:
        ap.error("at least one --arm NAME=PATH")
    arms, bins = [], {}
    os.makedirs(os.path.join(a.out, "bin"), exist_ok=True)
    for spec in a.arm:
        name, path = spec.split("=", 1)
        dst = os.path.join(a.out, "bin", name + "-nsvita-sim")
        shutil.copy2(path, dst)
        arms.append(name)
        bins[name] = dst
    with open(meta, "w") as f:
        json.dump({"arms": arms, "sites": names, "loads": a.loads,
                   "bins": {k: os.path.abspath(v) for k, v in bins.items()}},
                  f, indent=1)

    jobs = []
    for n in range(1, a.loads + 1):
        for arm in arms:
            for name, url in sites:
                jobs.append((n, arm, name, url))
    # each running load holds its own slot (its remote-control port)
    slots = queue.Queue()
    for i in range(a.jobs):
        slots.put(i)

    def one(d, name, url, sim):
        slot = slots.get()
        try:
            return scorecard.run_sim(d, name, url, slot, a.settle,
                                     a.timeout, sim)
        finally:
            slots.put(slot)

    with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        futs = {}
        for n, arm, name, url in jobs:
            d = os.path.join(a.out, arm, "L%d" % n)
            futs[ex.submit(one, d, name, url, bins[arm])] = (n, arm, name)
        for fu in concurrent.futures.as_completed(futs):
            n, arm, name = futs[fu]
            r = fu.result()
            with open(os.path.join(a.out, arm, "L%d" % n, "sim", name,
                                   "state.json"), "w") as f:
                json.dump({k: r.get(k) for k in ("state", "rc", "wall",
                                                 "done_s", "ready_ms")}, f)
            c = read_load(os.path.join(a.out, arm, "L%d" % n, "sim", name))
            print("L%d %-6s %-14s %-8s batch %d" % (n, arm, name, r["state"],
                                                   c["batch"]), flush=True)
    report(a.out, arms, names, a.loads)
    return 0


if __name__ == "__main__":
    sys.exit(main())
