#!/usr/bin/env python3
"""Load profile of one site in the simulator (doc 10, patch 476).

P1 of the run-43 device feedback: heavy pages take minutes on the Vita
(bbc 125.7 s, github 286 s) while small ones take 2-3 s on the same
Wi-Fi. This runs one site LOADS times in the simulator, to completion
(a long settle), and reports per load:

  done      the first "gw status: Done (Xs)" -- the figure the device
            numbers use (nav -> page Done)
  heap      the host heap at that Done and its peak over the load
            (mem[...] lines: patch 476's mallinfo2 stand-in for the
            device's arena; compare loads with loads, not with the device)
  llcache   objects created, destroyed, and REFETCHED -- a URL whose
            object was destroyed and then created again (the device's
            suspected thrash: a document's own CSS evicted mid-load)
  phases    from the engine log: layout ms (reformat), box + cascade ms
            (the conversion pipeline), JS compile / run / gc ms, full
            rebuilds, local rebuild ms
  cpu       with --sprof: where the CPU samples fall, bucketed by
            function (fetch/TLS, HTML parse, CSS parse, style selection,
            box build, layout, paint, font, image decode, JS, local
            rebuild, malloc, other)

The simulator is much faster than the device: read its milliseconds as a
relative proxy, weighted against the device's own numbers.

Usage:
  tools/scorecard/profile.py --out DIR [--site bbc | --url URL]
      [--sim PATH] [--loads 3] [--settle 60000] [--timeout 300]
      [--sprof]          (build tools/vita-sim/sprof.so if needed)
Writes DIR/profile.md and DIR/profile.json; loads land in DIR/L<n>/.
"""

import argparse
import collections
import json
import os
import pickle
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import scorecard  # noqa: E402

TOOLS = os.path.dirname(HERE)
SPROF_C = os.path.join(TOOLS, "vita-sim", "sprof.c")
SPROF_SYM = os.path.join(TOOLS, "vita-sim", "sprof-sym.py")

DONE_RE = re.compile(r"gw status: Done \((\d+(?:\.\d+)?)s\)")
MEM_RE = re.compile(r"mem\[([^\]]+)\]: host heap in use (\d+) KiB")
LAYOUT_RE = re.compile(r"LIFE reformat #\d+: layout (\d+) ms")
BOXCASC_RE = re.compile(r"box\+cascade DONE us=(\d+)")
# patch 491: JS run time by script, sampled every 10000 bytecode ops
JSSAMP_RE = re.compile(r"LIFE JSSAMP(\d+) (\S+) n=(\d+) pct=(\d+)")
JSSAMP_TOTAL_RE = re.compile(r"LIFE JSSAMP total=(\d+)")
JSPHASE_RE = re.compile(r"LIFE JSPHASE .*compile=(\d+)us run=(\d+)us "
                        r"gc=(\d+)us")
CREATED_RE = re.compile(r"llcache\.c:\d+ : Created object \S+ \((.*)\)$")
DESTROY_RE = re.compile(r"llcache\.c:\d+ : Destroying object (0x[0-9a-f]+)")
SIZE_RE = re.compile(r"llcache\.c:\d+ : Size: (\d+) \(limit: (\d+)\)")
EXIT_RE = re.compile(r"netsurf_exit:|quit requested")
CREATED_PTR_RE = re.compile(r"llcache\.c:\d+ : Created object (\S+) \(")
LOCAL_US_RE = re.compile(r"LIFE rebuild local: .* in (\d+) us \(")
FULL_RE = re.compile(r"LIFE BATCHCAUSE cause=")

# function-name prefixes -> phase (first match wins; leaf first)
BUCKETS = [
    ("fetch/TLS", ("curl_", "Curl_", "mbedtls_", "fetch_curl", "ssl_",
                   "[libcurl", "[libssl", "[libcrypto", "[libz", "inflate",
                   "llcache_", "fetch_")),
    ("HTML parse", ("hubbub_", "dom_hubbub", "treebuilder", "tokeniser",
                    "parserutils_", "html_process_data")),
    ("CSS parse", ("css__parse", "css__lexer", "css__language",
                   "css_stylesheet_", "css__stylesheet", "nscss_convert",
                   "css__propstrings", "parse_")),
    ("style selection", ("css_select", "css__select", "match_",
                         "css__get_", "css__compute", "css_computed_",
                         "node_", "named_", "box_get_style",
                         "nscss_get_style", "css__outranks", "cascade_")),
    ("box build", ("box_construct", "box_normalise", "convert_xml_to_box",
                   "box_create", "box_build", "dom_to_box",
                   "box_special", "html_rl_")),
    ("layout", ("layout_", "html_reformat", "content__reformat")),
    ("paint", ("html_redraw", "plot_", "vita_plot", "vita2d", "redraw",
               "browser_window_redraw", "knockout")),
    ("font", ("FT_", "[libfreetype", "nsfont", "vita_font", "font_",
              "utf8_")),
    ("image decode", ("png_", "[libpng", "jpeg", "[libjpeg", "nsgif",
                      "gif_", "rsvg", "svgtiny", "webp", "image_")),
    ("JS", ("JS_", "js_", "qjs_", "quickjs", "__JS", "lre_", "dom_js",
            "macsurf_qjs", "wasm")),
    ("DOM", ("dom_", "_dom_")),
    ("malloc", ("malloc", "free", "_int_", "calloc", "realloc",
                "talloc", "[libc.so")),
]


def bucket(stack):
    """stack: function names, leaf first (sprof-sym.py; the first two
    are the handler and the trampoline)."""
    for f in stack[2:6]:
        for name, prefixes in BUCKETS:
            if any(f.startswith(p) for p in prefixes):
                return name
    return "other"


def read_logs(d):
    data = os.path.join(d, "ux0:data", "VitaBrowser")
    r = {"done_s": None, "heap_done_kib": None, "heap_peak_kib": 0,
         "layout_ms": 0, "boxcascade_ms": 0.0, "js_compile_ms": 0.0,
         "js_run_ms": 0.0, "js_gc_ms": 0.0, "full_rebuilds": 0,
         "local_rebuild_ms": 0.0, "llc_created": 0, "llc_destroyed": 0,
         "llc_refetched": 0, "refetched_urls": [], "llc_size_peak": 0,
         "llc_limit": None, "jssamp": [], "jssamp_total": 0}
    try:
        for line in open(os.path.join(data, "log.txt"), errors="replace"):
            m = DONE_RE.search(line)
            if m and r["done_s"] is None:
                r["done_s"] = float(m.group(1))
            m = MEM_RE.search(line)
            if m:
                kib = int(m.group(2))
                r["heap_peak_kib"] = max(r["heap_peak_kib"], kib)
                if (m.group(1) == "page done" and r["done_s"] is not None
                        and r["heap_done_kib"] is None):
                    r["heap_done_kib"] = kib
    except OSError:
        pass
    seen, live = collections.Counter(), {}
    refetch = collections.Counter()
    exiting = False
    try:
        for line in open(os.path.join(data, "netsurf.log"), errors="replace"):
            line = line.rstrip("\n")
            if not exiting and EXIT_RE.search(line):
                exiting = True      # the exit's cleanup is not eviction
            m = SIZE_RE.search(line)
            if m and not exiting:
                r["llc_size_peak"] = max(r["llc_size_peak"], int(m.group(1)))
                r["llc_limit"] = int(m.group(2))
                continue
            m = LAYOUT_RE.search(line)
            if m:
                r["layout_ms"] += int(m.group(1))
                continue
            m = BOXCASC_RE.search(line)
            if m:
                r["boxcascade_ms"] += int(m.group(1)) / 1000.0
                continue
            m = JSSAMP_TOTAL_RE.search(line)
            if m:      # the main page's table is the largest
                if int(m.group(1)) >= r["jssamp_total"]:
                    r["jssamp_total"] = int(m.group(1))
                    r["jssamp_cur"] = []
                else:
                    r["jssamp_cur"] = None
                continue
            m = JSSAMP_RE.search(line)
            if m:
                if r.get("jssamp_cur") is not None:
                    r["jssamp_cur"].append((m.group(2), int(m.group(3)),
                                            int(m.group(4))))
                    r["jssamp"] = list(r["jssamp_cur"])
                continue
            m = JSPHASE_RE.search(line)
            if m:      # cumulative per page: keep the largest
                r["js_compile_ms"] = max(r["js_compile_ms"],
                                         int(m.group(1)) / 1000.0)
                r["js_run_ms"] = max(r["js_run_ms"], int(m.group(2)) / 1000.0)
                r["js_gc_ms"] = max(r["js_gc_ms"], int(m.group(3)) / 1000.0)
                continue
            if FULL_RE.search(line):
                r["full_rebuilds"] += 1
                continue
            m = LOCAL_US_RE.search(line)
            if m:
                r["local_rebuild_ms"] += int(m.group(1)) / 1000.0
                continue
            m = CREATED_RE.search(line)
            if m:
                url = m.group(1)
                r["llc_created"] += 1
                if seen[url]:
                    refetch[url] += 1
                seen[url] += 1
                p = CREATED_PTR_RE.search(line)
                if p:
                    live[p.group(1)] = url
                continue
            m = DESTROY_RE.search(line)
            if m and not exiting:
                r["llc_destroyed"] += 1
                live.pop(m.group(1), None)
    except OSError:
        pass
    r["llc_refetched"] = sum(refetch.values())
    r["refetched_urls"] = [u for u, _ in refetch.most_common(8)]
    return r


def sprof_buckets(d, binary):
    """symbolise the load's samples and bucket them"""
    outs = [f for f in os.listdir(d) if re.match(r"sprof\.\d+$", f)]
    if not outs:
        return None
    best = max(outs, key=lambda f: os.path.getsize(os.path.join(d, f)))
    path = os.path.join(d, best)
    subprocess.run([sys.executable, SPROF_SYM, path, binary],
                   capture_output=True, text=True)
    try:
        samples = pickle.load(open(path + ".pkl", "rb"))
    except OSError:
        return None
    c = collections.Counter(bucket(s[2]) for s in samples)
    leaves = collections.Counter(
        s[2][2] if len(s[2]) > 2 else "?" for s in samples)
    return {"samples": len(samples), "buckets": dict(c),
            "top": leaves.most_common(15)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--site", default="bbc")
    ap.add_argument("--url", default="")
    ap.add_argument("--sim", default=scorecard.SIM)
    ap.add_argument("--loads", type=int, default=3)
    ap.add_argument("--settle", type=int, default=60000)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--sprof", action="store_true")
    a = ap.parse_args()

    url, name = a.url, a.site
    if not url:
        for line in open(os.path.join(HERE, "sites.tsv")):
            if line.strip() and not line.startswith("#"):
                cols = line.rstrip("\n").split("\t")
                if cols[1].strip() == a.site:
                    url = cols[2].strip()
                    if len(cols) > 3 and cols[3].strip():
                        scorecard.BLOCK[name] = [h.strip().lower() for h in
                                                 cols[3].split(",")
                                                 if h.strip()]
        if not url:
            sys.exit("no site %r in sites.tsv" % a.site)
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    sprof_so = None
    if a.sprof:
        sprof_so = os.path.join(out, "sprof.so")
        subprocess.run(["gcc", "-O2", "-shared", "-fPIC", "-o", sprof_so,
                        SPROF_C, "-ldl"], check=True)
    binary = os.path.join(out, "nsvita-sim")
    subprocess.run(["cp", a.sim, binary], check=True)

    loads = []
    for n in range(1, a.loads + 1):
        d = os.path.join(out, "L%d" % n)
        env = None
        if sprof_so:
            env = {"LD_PRELOAD": sprof_so,
                   "SPROF_OUT": os.path.join(d, "sim", name, "sprof")}
        res = scorecard.run_sim(d, name, url, n, a.settle, a.timeout,
                                sim=binary, env_extra=env)
        ld = os.path.join(d, "sim", name)
        r = read_logs(ld)
        r["state"], r["wall_s"] = res.get("state"), res.get("wall")
        if sprof_so:
            r["cpu"] = sprof_buckets(ld, binary)
        loads.append(r)
        print("L%d %s done %s s, heap at done %s KiB (peak %s), llcache "
              "created %d destroyed %d refetched %d" % (
                  n, r["state"], r["done_s"], r["heap_done_kib"],
                  r["heap_peak_kib"], r["llc_created"], r["llc_destroyed"],
                  r["llc_refetched"]), flush=True)

    json.dump({"site": name, "url": url, "loads": loads},
              open(os.path.join(out, "profile.json"), "w"), indent=1)
    keys = [("done_s", "first Done (s)"), ("heap_done_kib", "heap at Done (KiB)"),
            ("heap_peak_kib", "heap peak (KiB)"),
            ("llc_created", "llcache objects created"),
            ("llc_destroyed", "llcache objects destroyed"),
            ("llc_refetched", "llcache refetched (created again)"),
            ("llc_size_peak", "llcache size peak (bytes)"),
            ("layout_ms", "layout (ms)"), ("boxcascade_ms", "box + cascade (ms)"),
            ("js_compile_ms", "JS compile (ms)"), ("js_run_ms", "JS run (ms)"),
            ("js_gc_ms", "JS gc (ms)"), ("full_rebuilds", "full rebuilds"),
            ("local_rebuild_ms", "local rebuilds (ms)")]
    md = ["# Load profile: %s (%s)" % (name, url), "",
          "| | " + " | ".join("L%d" % (i + 1) for i in range(len(loads))) + " |",
          "|---|" + "---|" * len(loads)]
    for k, label in keys:
        vals = []
        for r in loads:
            v = r.get(k)
            vals.append("-" if v is None else
                        ("%.1f" % v if isinstance(v, float) else str(v)))
        md.append("| %s | %s |" % (label, " | ".join(vals)))
    if sprof_so:
        md += ["", "## CPU samples by phase (percent of the load's samples)",
               "", "| phase | " + " | ".join("L%d" % (i + 1)
                                            for i in range(len(loads))) + " |",
               "|---|" + "---|" * len(loads)]
        phases = [b[0] for b in BUCKETS] + ["other"]
        for ph in phases:
            row = []
            for r in loads:
                cpu = r.get("cpu")
                if not cpu or not cpu["samples"]:
                    row.append("-")
                else:
                    row.append("%.1f" % (100.0 * cpu["buckets"].get(ph, 0) /
                                         cpu["samples"]))
            md.append("| %s | %s |" % (ph, " | ".join(row)))
        md.append("| (samples) | %s |" % " | ".join(
            str(r["cpu"]["samples"]) if r.get("cpu") else "-" for r in loads))
        if loads and loads[0].get("cpu"):
            md += ["", "Top leaf functions (L1):", ""]
            md += ["- %s: %d" % (f, c) for f, c in loads[0]["cpu"]["top"]]
    if loads and loads[0].get("jssamp"):
        md += ["", "JS run time by script (L1, %d samples x 10000 ops; "
               "timers, listeners and promise jobs included):" %
               loads[0]["jssamp_total"], ""]
        md += ["- %s: %d%% (%d)" % (n, pct, c)
               for n, c, pct in loads[0]["jssamp"][:8]]
    md += ["", "Refetched URLs (L1): " + (", ".join(loads[0]["refetched_urls"])
                                        if loads and loads[0]["refetched_urls"]
                                        else "none")]
    open(os.path.join(out, "profile.md"), "w").write("\n".join(md) + "\n")
    print("\n".join(md))
    return 0


if __name__ == "__main__":
    sys.exit(main())
