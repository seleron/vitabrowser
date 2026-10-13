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
  --mimic            what hsw-compare.py found the engine (268-272) answers
                     differently once the above are given: the Vita's screen
                     (960x544, pixelDepth 24), ontouchstart present, no
                     resource-timing entries (getEntriesByType('resource'))
  --add-globals FILE give window every name in FILE it lacks (one per line:
                     the engine's own -- its bridge's __vita* / __ms* / _k...),
                     as non-enumerable functions, as the engine has them
  --global-tag       window's own Symbol.toStringTag "global" (QuickJS's
                     global object has it: Object.prototype.toString(window)
                     is "[object global]", not "[object Window]")
  --own-layout FILE  the engine's own-property layout (JSON {object: [own
                     keys]}, from hsw-record.js's "K own" notes): each key
                     the engine has as an object's own property becomes one
                     in Chromium too, forwarding to Chromium's own value
                     (internal names get an empty function)
  --enum-keys FILE   Object.keys(window) becomes the names in FILE (the
                     engine's, one per line): those own properties made
                     enumerable, every other one not (order not matched)
  --blank-canvas     canvas read-back (toDataURL / toBlob / getImageData)
                     gives a blank canvas of the same size: what a page
                     sees from a raster that drew nothing
  --no-proto-uuid    Crypto.prototype.randomUUID deleted (the engine has
                     randomUUID only as crypto's own property)
  --transplant FILE  the getcaptcha request's fields named by --fields are
                     replaced, before hsw encrypts it, by those in FILE (a
                     request as hsw-record.js's "K json stringify" saw it:
                     the engine's); FILE's motionData keeps Chromium's own
                     timestamps shifted onto the engine's events
  --fields LIST      which fields (default motionData,pdc,pem,ws,clientOptions)
  --order FILE       window's configurable own properties are made again in
                     FILE's order (one name per line: the engine's
                     Object.getOwnPropertyNames(window)), after the other
                     flags -- so the two runs enumerate window alike
  --init FILE        one more init script (e.g. timing-probe.js); console
                     lines it writes that start with TMREC are printed
  --log-access       print every global / prototype member hCaptcha's frames
                     read (FPACC lines), to compare with the engine's surface
  --record DIR       record hsw for replay (hsw-record.js): DIR/<frame>.rec
                     per frame, replayed by hsw-replay.js in V8 and wasm3

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
    "'NavigatorUAData','NetworkInformation','StorageManager',"
    "'SpeechSynthesis','SubtleCrypto','DOMStringList',"
    "'MediaSource','MediaRecorder','OffscreenCanvas','RTCPeerConnection',"
    "'SVGTextContentElement','Temporal','caches','clientInformation',"
    "'speechSynthesis','MediaDevices'].forEach(function(k){delete window[k]});"
    "['mediaDevices','keyboard','webkitTemporaryStorage']"
    ".forEach(function(k){delete Navigator.prototype[k]});"
    "delete Document.prototype.featurePolicy;")
# (as of patch 272: Permissions, PerformanceResourceTiming, close, plugins,
# mimeTypes, performance.memory and screen.pixelDepth exist in the engine
# now, so they are no longer deleted here; the gap 5ae275c tested had them)


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


MIMIC = (getters("Screen.prototype", {
    "width": 960, "height": 544, "availWidth": 960, "availHeight": 544,
    "colorDepth": 24, "pixelDepth": 24, "availLeft": 0, "availTop": 0}) +
    "if(!('ontouchstart' in window))window.ontouchstart=null;"
    "(function(P){var g=P.getEntriesByType,e=P.getEntries,n=P.getEntriesByName;"
    "function f(l){return l.filter(function(x){return x.entryType!=='resource'})}"
    "P.getEntriesByType=function(t){return t==='resource'?[]:g.apply(this,arguments)};"
    "P.getEntries=function(){return f(e.apply(this,arguments))};"
    "P.getEntriesByName=function(){return f(n.apply(this,arguments))}})"
    "(Performance.prototype);"
    "['finalResponseHeadersStart','firstInterimResponseStart','renderBlockingStatus',"
    "'contentType','responseStatus','deliveryType','serverTiming','notRestoredReasons',"
    "'activationStart','criticalCHRestart','confidence']"
    ".forEach(function(k){delete PerformanceResourceTiming.prototype[k];"
    "delete PerformanceNavigationTiming.prototype[k]});")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--strip-gap", action="store_true")
    ap.add_argument("--globals")
    ap.add_argument("--values", action="store_true")
    ap.add_argument("--via-node", action="store_true")
    ap.add_argument("--touch", action="store_true")
    ap.add_argument("--cpu", type=float, default=1)
    ap.add_argument("--mimic", action="store_true")
    ap.add_argument("--add-globals")
    ap.add_argument("--global-tag", action="store_true")
    ap.add_argument("--own-layout")
    ap.add_argument("--enum-keys")
    ap.add_argument("--blank-canvas", action="store_true")
    ap.add_argument("--no-proto-uuid", action="store_true")
    ap.add_argument("--transplant")
    ap.add_argument("--fields", default="motionData,pdc,pem,ws,clientOptions")
    ap.add_argument("--order")
    ap.add_argument("--init", action="append", default=[])
    ap.add_argument("--log-access", action="store_true")
    ap.add_argument("--record")
    a = ap.parse_args()
    init = ""
    if a.strip_gap:
        init += STRIP_GAP
    if a.values:
        init += VALUES
    if a.mimic:
        # first: --strip-gap deletes the interface globals MIMIC patches
        init = MIMIC + init
    if a.globals:
        keep = [l.strip() for l in open(a.globals) if l.strip()]
        keep += ["window", "self", "document", "location", "top", "parent",
                 "frames", "globalThis", "navigator", "console"]
        init += ("(function(){var k={};%s.forEach(function(n){k[n]=1});"
                 "Object.getOwnPropertyNames(window).forEach(function(n){"
                 "if(!k[n]&&n.slice(0,2)!=='__'){try{delete window[n]}catch(e){}}})})();"
                 % json.dumps(sorted(set(keep))))
    if a.add_globals:
        add = sorted(set(l.strip() for l in open(a.add_globals) if l.strip()))
        # an own property each: a name window only inherits (the engine has
        # addEventListener / dispatchEvent / ... on window itself) keeps
        # its function, the others get an empty one
        init += ("(function(){%s.forEach(function(n){"
                 "if(Object.prototype.hasOwnProperty.call(window,n))return;"
                 "var v=window[n];Object.defineProperty(window,n,{value:"
                 "typeof v==='function'?v:function(){},writable:true,"
                 "configurable:true,enumerable:false})})})();" % json.dumps(add))
    if a.own_layout:
        lay = json.load(open(a.own_layout))
        init += ("(function(L){var T={navigator:navigator,document:document,screen:screen,"
                 "performance:performance,history:history,location:location,crypto:window.crypto,"
                 "'screen.orientation':screen.orientation,'Element.prototype':Element.prototype,"
                 "'Node.prototype':Node.prototype,'Function.prototype':Function.prototype,"
                 "'HTMLElement.prototype':HTMLElement.prototype,'EventTarget.prototype':EventTarget.prototype,"
                 "'Document.prototype':Document.prototype,'Navigator.prototype':Navigator.prototype};"
                 "Object.keys(L).forEach(function(k){var o=T[k];if(!o)return;L[k].forEach(function(n){"
                 "if(Object.prototype.hasOwnProperty.call(o,n))return;var p=Object.getPrototypeOf(o),d;"
                 "while(p&&!(d=Object.getOwnPropertyDescriptor(p,n)))p=Object.getPrototypeOf(p);"
                 "var e=n.charAt(0)!=='_';try{if(d&&d.get)Object.defineProperty(o,n,{get:function(){"
                 "return d.get.call(this)},set:d.set?function(v){d.set.call(this,v)}:undefined,"
                 "enumerable:e,configurable:true});else Object.defineProperty(o,n,{value:d?d.value:"
                 "(n.charAt(0)==='_'?function(){}:undefined),writable:true,enumerable:e,configurable:true})"
                 "}catch(x){}})})})(%s);" % json.dumps(lay))
    if a.enum_keys:
        ek = [l.strip() for l in open(a.enum_keys) if l.strip()]
        enum_init = ("(function(K){var k={};K.forEach(function(n){k[n]=1});"
                     "Object.getOwnPropertyNames(window).forEach(function(n){"
                     "var d=Object.getOwnPropertyDescriptor(window,n);"
                     "if(!d||!d.configurable||d.enumerable===!!k[n])return;"
                     "d.enumerable=!!k[n];try{Object.defineProperty(window,n,d)}catch(e){}})})(%s);"
                     % json.dumps(ek))
    if a.blank_canvas:
        init += ("(function(C,X){var td=C.toDataURL,tb=C.toBlob,gi=X.getImageData;"
                 "function blank(c){var b=document.createElement('canvas');b.width=c.width;"
                 "b.height=c.height;return b}"
                 "C.toDataURL=function(){return td.apply(blank(this),arguments)};"
                 "C.toBlob=function(){return tb.apply(blank(this),arguments)};"
                 "X.getImageData=function(x,y,w,h){return new ImageData(Math.max(1,Math.abs(w|0)),"
                 "Math.max(1,Math.abs(h|0)))}})"
                 "(HTMLCanvasElement.prototype,CanvasRenderingContext2D.prototype);")
    if a.no_proto_uuid:
        init += ("(function(f){delete Crypto.prototype.randomUUID;"
                 "Object.defineProperty(crypto,'randomUUID',{value:function randomUUID(){"
                 "return f.call(crypto)},writable:true,configurable:true,enumerable:true})})"
                 "(Crypto.prototype.randomUUID);")
    if a.transplant:
        donor = json.load(open(a.transplant))
        pick = {k: donor[k] for k in a.fields.split(",") if k in donor}
        init += ("(function(D){var S=JSON.stringify;JSON.stringify=function(o){"
                 "if(o&&typeof o==='object'&&'sitekey' in o&&'motionData' in o&&'n' in o){"
                 "var c={};for(var k in o)c[k]=o[k];for(var j in D)c[j]=D[j];"
                 "console.log('TRANSPLANT '+Object.keys(D).join(','));"
                 "arguments[0]=c}return S.apply(JSON,arguments)}})(%s);" % json.dumps(pick))
    if a.global_tag:
        init += ("Object.defineProperty(window,Symbol.toStringTag,{value:'global',"
                 "writable:false,enumerable:false,configurable:true});")
    if a.enum_keys:
        init += enum_init
    if a.order:
        order = [l.strip() for l in open(a.order) if l.strip()]
        init += ("(function(N){var D=Object.defineProperty,G=Object.getOwnPropertyDescriptor,"
                 "H=Object.prototype.hasOwnProperty;for(var i=0;i<N.length;i++){var k=N[i];"
                 "if(!H.call(window,k))continue;var d=G(window,k);if(!d||!d.configurable)continue;"
                 "try{delete window[k];D(window,k,d)}catch(e){}}})(%s);" % json.dumps(order))
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
        if a.record:
            os.makedirs(a.record, exist_ok=True)

            def rec(source, s):
                t, _, body = s.partition("\n")
                with open(os.path.join(a.record, t + ".rec"), "a") as f:
                    f.write(body + "\n")
            ctx.expose_binding("__hswRec", rec)
            ctx.add_init_script(path=os.path.join(HERE, "hsw-record.js"))
        for f in a.init:
            ctx.add_init_script(path=f)
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
        p.on("console", lambda m: print(m.text) if m.text.startswith(("FPACC", "INITERR", "TRANSPLANT", "TMREC")) else None)
        p.on("request", lambda r: sizes.append(len(r.post_data_buffer or b""))
             if "getcaptcha" in r.url else None)

        def resp(r):
            if "getcaptcha" in r.url:
                body = r.body()
                try:
                    j = json.loads(body)
                    kind = "json success=%s keys=%s" % (j.get("success"), ",".join(sorted(j)))
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
