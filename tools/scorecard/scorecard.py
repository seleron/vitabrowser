#!/usr/bin/env python3
"""VitaBrowser scorecard: real sites, measured against real Chrome.

Every site in sites.tsv is loaded twice: in the Vita simulator (the same
frontend and engine as the VPK) and in headless Chromium at the Vita's
960x544 with the Vita's user agent. Per site:

  state    loaded / timeout / crash (a crash scores 0)
  time     seconds to "Done" in the simulator
  errors   distinct JS exceptions in the engine log (Chrome's page errors
           shown beside them: the page's own noise is not our bug)
  text     recall of Chrome's visible words: of the 400 most frequent
           words Chrome shows, the share our document holds
  visual   first-screen similarity: structure (where the ink is, 16 px
           blocks) and tone (8 px block means), 0..1
  score    100 * (0.15 loaded + 0.45 text + 0.40 visual)

Scores are only comparable run to run on the same machine and day (live
sites change), so a run also writes the reference it used; --reuse-ref
keeps Chrome's side fixed while the browser changes.

A site's optional fourth sites.tsv column lists hosts (comma-separated,
subdomains included) blocked on BOTH sides: the simulator's user
blocklist.txt and a request abort in Chromium. It is for third-party
overlays whose arrival races the screenshot or is sampled at random.
BBC's consent dialog (cdn.privacy-mgmt.com) loaded in Chrome every time
but in the simulator only sometimes, and its "Help us improve!" survey
invite (edigitalsurvey.com) picks a random share of visits, so the same
build scored anywhere from ~75 to ~90 run to run.

Usage:
  tools/scorecard/scorecard.py --out DIR [--only a,b] [--reuse-ref DIR]
      [--jobs 4] [--settle 15000] [--baseline DIR/scores.json]

Needs: an nsvita-sim build (tools/run-vita-sim.sh or the simbuild), the
simulator's app0: tree ($WORK/vita-sim/run/app0:), python3 + numpy, and
playwright (Chromium) for the reference side.
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import zlib

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.environ.get("WORK", os.path.expanduser("<WORK>/vitabrowser-work"))
SIM = os.path.join(WORK, "applytest/upstream/netsurf/nsvita-sim")
BLOCK = {}	# site name -> hosts blocked on both sides (sites.tsv col 4)
APP0 = os.path.join(WORK, "vita-sim/run/app0:")
UA = ("Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like "
      "Gecko) Chrome/140.0.0.0 Mobile Safari/537.36")
W, H = 960, 544
# the simulator's frame: a 20 px title bar on top, a 22 px HUD below
SIM_TOP, SIM_BOTTOM = 20, 522

# Text extraction, the same function on both sides. Our engine may lack
# innerText; textContent then stands in (it over-counts script text, which
# can only raise recall, never lower it).
TEXT_JS = r"""
(function () {
  var b = document.body; if (!b) return '';
  var t = '';
  try { t = b.innerText; } catch (e) { }
  if (typeof t !== 'string' || !t) { try { t = b.textContent || ''; } catch (e) { t = ''; } }
  return String(t).replace(/\s+/g, ' ').slice(0, 30000);
})()
"""

SIM_EVAL_JS = r"""
setTimeout(function () {
  var t = """ + TEXT_JS.strip() + r""";
  var n = Math.ceil(t.length / 240);
  console.log('VBTXTN ' + n + ' ' + t.length + ' ' + location.href);
  for (var i = 0; i < n; i++) console.log('VBTXT' + i + ' ' + t.slice(i * 240, i * 240 + 240));
}, 10);
"""


# ---- PNG (8-bit RGB/RGBA, non-interlaced) ------------------------------

def read_png(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG: " + path)
    pos, idat, w = 8, [], None
    while pos < len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or inter:
                raise ValueError("unsupported PNG %s" % path)
            bpp = 3 if ctype == 2 else 4
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
        pos += 12 + n
    raw = zlib.decompress(b"".join(idat))
    stride = w * bpp
    out = np.zeros((h, stride), dtype=np.uint8)
    prev = np.zeros(stride, dtype=np.int32)
    for y in range(h):
        ft = raw[y * (stride + 1)]
        line = np.frombuffer(raw, dtype=np.uint8, count=stride,
                             offset=y * (stride + 1) + 1).astype(np.int32)
        if ft == 0:
            cur = line
        elif ft == 2:
            cur = (line + prev) & 0xff
        else:
            cur = np.zeros(stride, dtype=np.int32)
            for i in range(stride):
                a = cur[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                if ft == 1:
                    p = a
                elif ft == 3:
                    p = (a + b) >> 1
                else:
                    pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                    p = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                cur[i] = (line[i] + p) & 0xff
        out[y] = cur
        prev = cur
    img = out.reshape(h, w, bpp)[:, :, :3]
    return img


def gray(img):
    return (0.299 * img[:, :, 0] + 0.587 * img[:, :, 1] +
            0.114 * img[:, :, 2]).astype(np.float32)


def blocks(g, s):
    h, w = (g.shape[0] // s) * s, (g.shape[1] // s) * s
    return g[:h, :w].reshape(h // s, s, w // s, s)


def visual_similarity(ours, ref):
    """0..1: where the ink is (IoU of 16 px blocks that are not flat
    background) and the tone (8 px block means)."""
    a, b = gray(ours), gray(ref)
    h = min(a.shape[0], b.shape[0])
    a, b = a[:h, :W], b[:h, :W]
    ta, tb = blocks(a, 8).mean(axis=(1, 3)), blocks(b, 8).mean(axis=(1, 3))
    tone = 1.0 - float(np.abs(ta - tb).mean()) / 255.0
    ia = blocks(a, 16).std(axis=(1, 3)) > 6.0
    ib = blocks(b, 16).std(axis=(1, 3)) > 6.0
    union = np.logical_or(ia, ib).sum()
    iou = float(np.logical_and(ia, ib).sum()) / union if union else 1.0
    return round(0.6 * iou + 0.4 * tone, 3)


# ---- words ------------------------------------------------------------

WORD = re.compile(r"[a-z0-9À-ɏ]{3,}")


def top_words(text, n=400):
    counts = {}
    for w in WORD.findall(text.lower()):
        counts[w] = counts.get(w, 0) + 1
    return [w for w, _ in sorted(counts.items(), key=lambda kv: -kv[1])[:n]]


def recall(ref_text, our_text):
    ref = top_words(ref_text)
    if not ref:
        return None
    ours = set(WORD.findall(our_text.lower()))
    return round(sum(1 for w in ref if w in ours) / len(ref), 3)


# ---- the simulator side -----------------------------------------------

ERR_RE = re.compile(r"(unhandled rejection|THREW|timer exc|job exc|"
                    r"exec module done ok=0|LIFE js exc|script exc|"
                    r"handler exc|qjs FATAL)")
DONE_RE = re.compile(r"gw status: Done \((\d+(?:\.\d+)?)s\)")
JSERR_RE = re.compile(r"(TypeError|ReferenceError|SyntaxError|RangeError|"
                      r"InternalError): [^\[|]{0,80}")


def run_sim(outdir, name, url, slot, settle, timeout):
    d = os.path.join(outdir, "sim", name)
    shutil.rmtree(d, ignore_errors=True)
    data = os.path.join(d, "ux0:data", "VitaBrowser")
    os.makedirs(data)
    os.makedirs(os.path.join(d, "shots"))
    shutil.copytree(APP0, os.path.join(d, "app0:"))
    with open(os.path.join(data, "netlog.cfg"), "w") as f:
        f.write("off\n")
    if BLOCK.get(name):
        with open(os.path.join(data, "blocklist.txt"), "w") as f:
            f.write("".join(h + "\n" for h in BLOCK[name]))
    evaljs = os.path.join(d, "text.js")
    with open(evaljs, "w") as f:
        f.write(SIM_EVAL_JS)
    script = os.path.join(d, "script.txt")
    with open(script, "w") as f:
        f.write("settle %d\neval %s\nsettle 1500\nshot first\nquit\n"
                % (settle, evaljs))
    env = dict(os.environ, VITA_SIM_SCRIPT=script, VITA_CSSGAP="1",
               VITA_SIM_OUT=os.path.join(d, "shots"),
               VITA_SIM_REMOTE_PORT=str(45300 + slot))
    t0 = time.time()
    with open(os.path.join(d, "out.log"), "w") as log:
        try:
            p = subprocess.run([SIM, url], cwd=d, env=env, stdout=log,
                               stderr=subprocess.STDOUT, timeout=timeout)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            rc = "timeout"
    wall = round(time.time() - t0, 1)
    res = {"rc": rc, "wall": wall}
    out = open(os.path.join(d, "out.log"), errors="replace").read()
    crashed = rc not in (0, "timeout") or any(
        m in out for m in ("Assertion", "Segmentation", "dumped core"))
    res["state"] = "crash" if crashed else ("timeout" if rc == "timeout"
                                            else "loaded")
    done, title = None, ""
    try:
        for line in open(os.path.join(data, "log.txt"), errors="replace"):
            m = DONE_RE.search(line)
            if m and done is None:
                done = float(m.group(1))
            if "gw title: " in line:
                title = line.split("gw title: ", 1)[1].strip()
    except OSError:
        pass
    res["done_s"], res["title"] = done, title
    chunks, errs, gaps, jsgaps = {}, set(), set(), set()
    try:
        for line in open(os.path.join(data, "netsurf.log"), errors="replace"):
            m = re.match(r"MS \[js\] VBTXT(\d+) (.*)", line.rstrip("\n"))
            if m:
                chunks[int(m.group(1))] = m.group(2)
                continue
            g = re.match(r"MS CSSGAP (\w+) ([^:]+): ?(.*)", line)
            if g:
                val = g.group(3).strip()
                head = re.split(r"[ (,]", val, 1)[0] if val else ""
                gaps.add("%s %s: %s" % (g.group(1), g.group(2), head))
                continue
            if ERR_RE.search(line):
                errs.add(line.strip()[:160])
                j = JSERR_RE.search(line)
                if j:
                    jsgaps.add(re.sub(r"'[^']*'", "'…'", j.group(0))[:90])
    except OSError:
        pass
    res["text"] = "".join(chunks[i] for i in sorted(chunks))
    res["errors"] = len(errs)
    res["cssgaps"] = sorted(gaps)
    res["jsgaps"] = sorted(jsgaps)
    res["error_samples"] = sorted(errs)[:5]
    shot = os.path.join(d, "shots", "first.png")
    res["shot"] = shot if os.path.isfile(shot) else None
    return res


def rescore_text(outdir, name):
    chunks = {}
    path = os.path.join(outdir, "sim", name, "ux0:data", "VitaBrowser",
                        "netsurf.log")
    for line in open(path, errors="replace"):
        m = re.match(r"MS \[js\] VBTXT(\d+) (.*)", line.rstrip("\n"))
        if m:
            chunks[int(m.group(1))] = m.group(2)
    return "".join(chunks[i] for i in sorted(chunks))


# ---- the Chrome side --------------------------------------------------

def _blocker(hosts):
    """A Playwright route handler aborting requests to hosts (and their
    subdomains), as the simulator's blocklist matches them."""
    def handle(route):
        host = route.request.url.split("/")[2].split(":")[0].lower()
        if any(host == h or host.endswith("." + h) for h in hosts):
            route.abort()
        else:
            route.continue_()
    return handle


def run_chrome(refdir, sites, settle_ms):
    from playwright.sync_api import sync_playwright
    os.makedirs(refdir, exist_ok=True)
    out = {}
    with sync_playwright() as pw:
        b = pw.chromium.launch()
        for tier, name, url in sites:
            ctx = b.new_context(viewport={"width": W, "height": H},
                                user_agent=UA, locale="en-IE")
            ctx.add_cookies([{"name": "SOCS", "value": "CAI", "domain": d,
                              "path": "/"} for d in (".google.com",
                                                     ".youtube.com")])
            if BLOCK.get(name):
                ctx.route("**/*", _blocker(BLOCK[name]))
            p = ctx.new_page()
            errors = []
            p.on("pageerror", lambda e: errors.append(str(e)[:160]))
            r = {"ok": False}
            try:
                p.goto(url, wait_until="load", timeout=45000)
                p.wait_for_timeout(min(settle_ms, 6000))
                p.screenshot(path=os.path.join(refdir, name + ".png"))
                r = {"ok": True, "title": p.title(),
                     "text": p.evaluate(TEXT_JS), "errors": len(errors)}
            except Exception as e:  # noqa: BLE001 -- recorded, not fatal
                r = {"ok": False, "why": str(e)[:200]}
            out[name] = r
            ctx.close()
        b.close()
    with open(os.path.join(refdir, "ref.json"), "w") as f:
        json.dump(out, f)
    return out


# ---- report -------------------------------------------------------------

# A bot wall is not a rendering result: on Chrome's side it makes the
# reference unusable (the site is left out of the tier means), on ours it
# is reported as "blocked" (WS-F), not as a layout failure.
WALL = re.compile(r"(just a moment|unusual traffic|verify you are (a )?human|"
                  r"are you a robot|captcha|access denied|attention required|"
                  r"please enable (js|javascript)|welcome to reddit|"
                  r"if this persists, please email us|blocked by network security)",
                  re.I)


def is_wall(title, text):
    return bool(WALL.search(title or "")) or (
        len(text or "") < 1500 and bool(WALL.search(text or "")))


def score(res, ref, name, refdir):
    rr = ref.get(name, {})
    res["ref_state"] = ("missing" if not rr.get("ok") else
                        "blocked" if is_wall(rr.get("title"), rr.get("text"))
                        else "ok")
    if res["state"] == "loaded" and is_wall(res.get("title"), res.get("text")):
        res["state"] = "blocked"
    if res["state"] == "crash":
        res.update(text_recall=0.0, visual=0.0, score=0.0)
        return
    if res["ref_state"] == "blocked":
        rr = {}
    res["text_recall"] = recall(rr.get("text", ""), res["text"]) \
        if rr.get("ok") else None
    refpng = os.path.join(refdir, name + ".png")
    res["visual"] = None
    if res["shot"] and os.path.isfile(refpng):
        ours = read_png(res["shot"])[SIM_TOP:SIM_BOTTOM]
        chrome = read_png(refpng)[:SIM_BOTTOM - SIM_TOP]
        res["visual"] = visual_similarity(ours, chrome)
    loaded = {"loaded": 1.0, "timeout": 0.5}.get(res["state"], 0.0)
    t = res["text_recall"] if res["text_recall"] is not None else loaded
    v = res["visual"] if res["visual"] is not None else t
    res["score"] = round(100 * (0.15 * loaded + 0.45 * t + 0.40 * v), 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--sites", default=os.path.join(HERE, "sites.tsv"))
    ap.add_argument("--only", default="")
    ap.add_argument("--reuse-ref", default="")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--settle", type=int, default=15000)
    ap.add_argument("--timeout", type=int, default=240)
    ap.add_argument("--baseline", default="")
    ap.add_argument("--rescore", action="store_true",
                    help="recompute scores of an existing --out run")
    a = ap.parse_args()

    sites = []
    for line in open(a.sites):
        if line.strip() and not line.startswith("#"):
            cols = line.rstrip("\n").split("\t")
            tier, name, url = cols[:3]
            sites.append((tier.strip(), name.strip(), url.strip()))
            if len(cols) > 3 and cols[3].strip():
                BLOCK[name.strip()] = [h.strip().lower() for h in
                                       cols[3].split(",") if h.strip()]
    if a.only:
        keep = set(a.only.split(","))
        sites = [s for s in sites if s[1] in keep]
    os.makedirs(a.out, exist_ok=True)

    refdir = a.reuse_ref or os.path.join(a.out, "ref")
    # a run's directory names its reference too (DIR/ref). A --reuse-ref
    # without a ref.json is an error: it used to take a fresh reference and
    # write it into that directory -- into another run's, when given one.
    if a.reuse_ref and not os.path.isfile(os.path.join(refdir, "ref.json")):
        if os.path.isfile(os.path.join(refdir, "ref", "ref.json")):
            refdir = os.path.join(refdir, "ref")
        else:
            ap.error("--reuse-ref %s: no ref.json there or in its ref/" % refdir)
    if a.reuse_ref:
        ref = json.load(open(os.path.join(refdir, "ref.json")))
    else:
        ref = run_chrome(refdir, sites, a.settle)

    results = {}
    if a.rescore:
        prev = json.load(open(os.path.join(a.out, "scores.json")))
        for tier, name, url in sites:
            r = dict(prev[name])
            try:
                r["text"] = rescore_text(a.out, name)
            except OSError:
                r["text"] = ""
            score(r, ref, name, refdir)
            results[name] = r
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        futs = {} if a.rescore else {
            ex.submit(run_sim, a.out, name, url, i % a.jobs, a.settle,
                      a.timeout): (tier, name, url)
            for i, (tier, name, url) in enumerate(sites)}
        for fu in concurrent.futures.as_completed(futs):
            tier, name, url = futs[fu]
            r = fu.result()
            r.update(tier=tier, url=url)
            score(r, ref, name, refdir)
            results[name] = r
            print("%-14s %-8s ref %-7s %5s  text %-5s visual %-5s err %-3s %s" % (
                name, r["state"], r["ref_state"], r["score"], r["text_recall"],
                r["visual"], r["errors"], (r["title"] or "")[:40]),
                flush=True)

    base = json.load(open(a.baseline)) if a.baseline else {}
    lines = ["# VitaBrowser scorecard", "",
             "| tier | site | state | ref | score | Δ | text | visual | JS err (Chrome) | Done s |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    tiers = {}
    for tier, name, url in sites:
        r = results[name]
        rr = ref.get(name, {})
        b = base.get(name, {}).get("score")
        delta = "" if b is None else "%+.1f" % (r["score"] - b)
        if r["ref_state"] == "ok" or r["state"] == "crash":
            tiers.setdefault(tier, []).append(r["score"])
        lines.append("| %s | [%s](%s) | %s | %s | %s | %s | %s | %s | %s (%s) | %s |" % (
            tier, name, url, r["state"], r["ref_state"], r["score"], delta,
            r["text_recall"],
            r["visual"], r["errors"], rr.get("errors", "-"), r["done_s"]))
    lines += ["", "| tier | mean score |", "|---|---|"]
    allv = []
    for tier, v in tiers.items():
        allv += v
        lines.append("| %s | %.1f |" % (tier, sum(v) / len(v)))
    lines.append("| **all** | **%.1f** |" % (sum(allv) / len(allv)))
    with open(os.path.join(a.out, "scorecard.md"), "w") as f:
        f.write("\n".join(lines) + "\n")
    # the gap census: each dropped CSS declaration / JS error message,
    # ranked by how many sites hit it
    for key, title in (("cssgaps", "CSS declarations dropped"),
                       ("jsgaps", "JavaScript errors")):
        count = {}
        for name, r in results.items():
            for g in r.get(key, []):
                count.setdefault(g, []).append(name)
        rows = sorted(count.items(), key=lambda kv: (-len(kv[1]), kv[0]))
        with open(os.path.join(a.out, key + ".md"), "w") as f:
            f.write("# %s, by number of sites\n\n| sites | gap | where |\n"
                    "|---|---|---|\n" % title)
            for g, names in rows:
                f.write("| %d | `%s` | %s |\n" % (len(names), g.replace("|", "\\|"),
                                                   ", ".join(sorted(names))))
    slim = {k: {kk: vv for kk, vv in v.items() if kk != "text"}
            for k, v in results.items()}
    with open(os.path.join(a.out, "scores.json"), "w") as f:
        json.dump(slim, f, indent=1)
    print("\n".join(lines[-(len(tiers) + 3):]))


if __name__ == "__main__":
    sys.exit(main())
