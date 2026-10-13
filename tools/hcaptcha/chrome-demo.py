#!/usr/bin/env python3
"""hCaptcha's public demo in headless Chromium: does getcaptcha hand out a
challenge? Each flag gives Chromium one of the engine's differences, to see
which (if any) turns the challenge into the refusal the engine gets
(docs/wasm-hcaptcha-measurement.md, "Why hCaptcha refuses us").

  --strip-gap        delete what hCaptcha's frame reads that the engine
                     lacks: WebGL (getContext('webgl') -> null), the audio
                     interfaces, plugins / mimeTypes / mediaDevices, ...
  --globals FILE     delete every window property not named in FILE (one
                     per line: the engine's Object.getOwnPropertyNames(window))
  --values           the engine's navigator / screen values and time zone
  --via-node         send api.hcaptcha.com requests through Playwright's own
                     HTTP client (not Chrome's TLS), without sec-* headers
  --touch            tap the checkbox (touch) instead of clicking it
  --cpu N            CPU throttling (site isolation off so frames share it)
  --log-access       print every global / prototype member hCaptcha's frames
                     read (FPACC lines), to compare with the engine's surface

Usage: /usr/bin/python3 tools/hcaptcha/chrome-demo.py [flags]
Prints the getcaptcha answer: "challenge" (encrypted, ~2.4 KB) or
"json success=False" (the refusal, ~0.8 KB).
"""
import argparse, json, os
from playwright.sync_api import sync_playwright

UA = ("Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like "
      "Gecko) Chrome/140.0.0.0 Mobile Safari/537.36")
DEMO = "https://accounts.hcaptcha.com/demo"
HERE = os.path.dirname(os.path.abspath(__file__))

STRIP_GAP = (
    "delete window.WebGLRenderingContext;delete window.WebGL2RenderingContext;"
    "(function(g){HTMLCanvasElement.prototype.getContext=function(t){"
    "if(/webgl/.test(t))return null;return g.apply(this,arguments)}})"
    "(HTMLCanvasElement.prototype.getContext);"
    "['BaseAudioContext','OfflineAudioContext','AudioBuffer','AnalyserNode',"
    "'AudioContext','webkitOfflineAudioContext','webkitAudioContext',"
    "'NavigatorUAData','Permissions','NetworkInformation','StorageManager',"
    "'SpeechSynthesis','SubtleCrypto','DOMStringList','PerformanceResourceTiming',"
    "'MediaSource','MediaRecorder','OffscreenCanvas','RTCPeerConnection',"
    "'SVGTextContentElement','Temporal','caches','clientInformation',"
    "'speechSynthesis','close','MediaDevices'].forEach(function(k){delete window[k]});"
    "['plugins','mimeTypes','mediaDevices','keyboard','webkitTemporaryStorage']"
    ".forEach(function(k){delete Navigator.prototype[k]});"
    "delete Performance.prototype.memory;delete Screen.prototype.pixelDepth;"
    "delete Document.prototype.featurePolicy;")


def getters(proto, d):
    return "".join("Object.defineProperty(%s,%s,{get:function(){return %s},"
                   "configurable:true});" % (proto, json.dumps(k), json.dumps(v))
                   for k, v in d.items())


VALUES = (getters("Navigator.prototype", {
    "vendor": "Anthropic/MPLS", "product": "MacSurf", "productSub": "20260531",
    "hardwareConcurrency": 1, "deviceMemory": 0.5, "maxTouchPoints": 5,
    "platform": "Linux armv8l", "doNotTrack": "1", "webdriver": False,
    "language": "en-US", "languages": ["en-US"]}) +
    getters("Screen.prototype", {"width": 1024, "height": 768,
                                 "availWidth": 1024, "availHeight": 740}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--strip-gap", action="store_true")
    ap.add_argument("--globals")
    ap.add_argument("--values", action="store_true")
    ap.add_argument("--via-node", action="store_true")
    ap.add_argument("--touch", action="store_true")
    ap.add_argument("--cpu", type=float, default=1)
    ap.add_argument("--log-access", action="store_true")
    a = ap.parse_args()
    init = ""
    if a.strip_gap:
        init += STRIP_GAP
    if a.values:
        init += VALUES
    if a.globals:
        keep = [l.strip() for l in open(a.globals) if l.strip()]
        keep += ["window", "self", "document", "location", "top", "parent",
                 "frames", "globalThis", "navigator", "console"]
        init += ("(function(){var k={};%s.forEach(function(n){k[n]=1});"
                 "Object.getOwnPropertyNames(window).forEach(function(n){"
                 "if(!k[n]){try{delete window[n]}catch(e){}}})})();"
                 % json.dumps(sorted(set(keep))))
    slow = max(1, a.cpu / 3)
    out, sizes = [], []
    with sync_playwright() as pw:
        args = ["--disable-site-isolation-trials",
                "--disable-features=IsolateOrigins,site-per-process"] if a.cpu > 1 else []
        b = pw.chromium.launch(args=args)
        kw = dict(viewport={"width": 960, "height": 544}, user_agent=UA,
                  locale="en-IE", has_touch=a.touch)
        if a.values:
            kw["timezone_id"] = "Etc/GMT-1"
        ctx = b.new_context(**kw)
        if a.log_access:
            ctx.add_init_script(path=os.path.join(HERE, "access-log.js"))
        if init:
            ctx.add_init_script(script="try{" + init + "}catch(e){console.log('INITERR '+e)}")
        if a.via_node:
            def handle(route):
                r = route.request
                h = {k: v for k, v in r.headers.items()
                     if not k.startswith("sec-") and k != "priority"}
                route.fulfill(response=route.fetch(headers=h))
            ctx.route("https://api.hcaptcha.com/**", handle)
        p = ctx.new_page()
        if a.cpu > 1:
            ctx.new_cdp_session(p).send("Emulation.setCPUThrottlingRate", {"rate": a.cpu})
        p.on("console", lambda m: print(m.text) if m.text.startswith(("FPACC", "INITERR")) else None)
        p.on("request", lambda r: sizes.append(len(r.post_data_buffer or b""))
             if "getcaptcha" in r.url else None)

        def resp(r):
            if "getcaptcha" in r.url:
                body = r.body()
                try:
                    kind = "json success=%s" % json.loads(body).get("success")
                except ValueError:
                    kind = "challenge"
                out.append("%s (%d bytes)" % (kind, len(body)))
        p.on("response", resp)
        p.goto(DEMO, wait_until="load", timeout=120000)
        p.wait_for_timeout(int(6000 * slow))
        for f in p.frames:
            if "frame=checkbox" in f.url:
                if a.touch:
                    bb = f.frame_element().bounding_box()
                    p.touchscreen.tap(bb["x"] + 30, bb["y"] + bb["height"] / 2)
                else:
                    f.click("#checkbox", timeout=60000)
        p.wait_for_timeout(int(12000 * slow))
        b.close()
    print("getcaptcha sent %s bytes; answer: %s" % (sizes, out or "none"))


if __name__ == "__main__":
    main()
