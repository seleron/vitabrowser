# WebAssembly for hCaptcha: measured, not built (2026-10-11)

Question (loop task a): can our engine run hCaptcha's proof-of-work
WebAssembly module (hsw.js), and at what cost on the Vita? Implement if
feasible.

**Answer: an interpreter can run it, but building it now would not get
anyone signed in, and no other scored site needs WebAssembly.** The
numbers and what has to come first are below.

## The module

hsw.js (1.1 MB, newassets.hcaptcha.com/c/<hash>/hsw.js) instantiates one
module of 698 724 bytes: wasm-bindgen output with 182 function imports
("a".*: browser fingerprinting through JS) and 21 exports.

- Pure **WebAssembly 1.0 (MVP)**: a full opcode walk of all 839 functions
  (301 046 instructions) found no SIMD, bulk-memory, reference-type,
  sign-extension, multi-value or tail-call opcodes; no multi-result
  types.
- One memory (18 pages initial = 1.1 MB, no maximum), one funcref table
  (159), no start function.

Any MVP interpreter runs it. wasm3 v0.5.0 (MIT, portable C) parses, loads
and compiles all 839 functions in **77 ms** on the host (Chromium: about
350 ms to instantiate it).

## What it costs

Chromium (`claude.ai/login`, hooking WebAssembly.instantiate and timing
every export call in every frame), per challenge frame: about **250-285
ms** inside exported functions, over **118 000-249 000 JS<->WASM calls**;
the largest single call is 120-180 ms. Two challenge frames each run it.

Interpreter vs JIT on hsw's own code: internal functions whose call trees
touch no imports were re-exported and called identically in Node 24
(TurboFan, and Liftoff only) and in wasm3 (-O3):

| function | TurboFan | Liftoff | wasm3 | wasm3 / TurboFan |
|---|---|---|---|---|
| 365 (x60) | 20.3 ms | 32.2 ms | 145.7 ms | 7.2x |
| 305 (x400) | 2.65 ms | 2.90 ms | 10.95 ms | 4.1x |
| 800 (x400) | 1.16 ms | 1.00 ms | 2.34 ms | 2.0x |
| 276 (x400) | 1.05 ms | 1.01 ms | 2.15 ms | 2.0x |

The heaviest function is the honest one: about 7x.

Host to Vita for interpreter code: the autotest's `fib(25)` (QuickJS,
also a bytecode interpreter) takes 9 ms in the simulator and 286 ms on the
PCH-2000 (run 27): **32x**.

**Vita estimate:**

- **The WebAssembly itself:** about 250 ms x 7 x 32 = **56 s per frame**,
  so about **2 minutes** for claude.ai's two frames.
- **Around it:** about 5 s of compilation, and several seconds for the
  QuickJS glue across about 250 000 boundary calls.
- **The UI:** a single m3_Call cannot yield, so the largest call alone
  would freeze the page for about **40 s**.

The token's time limit is not the problem: the hsw request JWT from
checksiteconfig expires about an hour after it is issued (`e`), and its
difficulty is low (`s: 4`).

## Why it would not get anyone signed in

**Even real Chromium gets a visual challenge.** Headless Chromium with a
normal user agent runs hsw and then gets "Click all the animals that match
the example" (challenge-ready 520x570), and `hcaptcha.execute()` stays
pending. A Vita would get the same, or worse.

**We can't draw that challenge.** Our canvas 2D context is a no-op stub
(fillText / drawImage / putImageData do nothing, fixes1245), so the
challenge grid would be blank. hsw also fingerprints through canvas,
reading toDataURL / getImageData, which would answer from that stub.

**Nothing else needs it.** No other site in the scorecard probes for
WebAssembly: `WANT WebAssembly` appears on 1 of 21 sites (claude.ai).

## What would have to come first, in order

1. **A real canvas 2D raster**: fill/stroke paths, drawImage, text,
   get/putImageData, toDataURL, composited as the canvas element's image.
   Wider value than hCaptcha (charts, games, sites that draw text). This
   is a project of its own. **Done 2026-10-11, patch 251** (see doc 10,
   "Since run 30"): hsw's toDataURL / getImageData now read real pixels,
   and the challenge grid has something to draw into. Left for a captcha:
   shadows and filters (not used by the grid), rotated text.
2. **WebAssembly with time slicing** -- **done 2026-10-12, patch 254**
   (doc 10, "Since run 32"), with one change from the plan below: no
   worker thread. A call still blocks scripts, but the frontend draws the
   page every 200 ms of it and CIRCLE stops it; the script budget does
   not count the time. hsw itself has not been run yet (it needs the
   live site): that is step 3. Planned as: wasm3 behind a JS
   WebAssembly.instantiate / Module / Instance / Memory API.
   - Imports: one trampoline per signature.
   - Memory: exported as an ArrayBuffer over wasm3's memory, detached and
     re-made when it grows.
   - Errors: a JS exception thrown inside an import is carried through
     the trap.
   - Yielding: the call must run on a worker thread, or be interruptible,
     so the UI can repaint during a 40 s call.
3. Only then is an hCaptcha attempt meaningful, and it would still end
   at an image challenge solved by touch inside a cross-site frame.
   **Run live in the simulator 2026-10-12** (doc 10, "Since run 33"):
   hsw runs -- one long call per challenge frame, about 590 ms on the
   host (Chromium: 250-285 ms in all of a frame's export calls), so
   roughly 20 s per frame on the Vita rather than the 56 s estimated
   below. Two engine bugs on the way: a crash when the challenge frame
   forced a relayout (patch 255), and binary request bodies sent as text
   (patch 256: getcaptcha's 32 KB msgpack answer got a 415). With both
   fixed the server answers `success: false` with a fresh hsw request,
   where Chromium gets its encrypted challenge. The guess then -- hsw's
   fingerprint of this engine, about 25 interfaces missing under a Chrome
   user agent -- was **tested 2026-10-13 and is wrong**: see below.

## Why hCaptcha refuses us: what it is not (2026-10-13)

Measured on hCaptcha's public demo (accounts.hcaptcha.com/demo: the same
hsw, and no sign-in email is sent), simulator at c7b26d1 (patches
168-267). Tools: `tools/hcaptcha/` (the scripts are kept this time).

**The refusal.** Tapping the checkbox in the simulator posts a 25-26 KB
getcaptcha body and gets 797 bytes back: `success: false` with a fresh
hsw request. Headless Chromium (same machine, same Chrome 140 Android user
agent, 960x544) posts 36-43 KB and gets its 2.4 KB encrypted challenge.
The body is msgpack `[<the hsw request>, <a blob hsw encrypts>]`, so what
differs inside it cannot be read.

**What hCaptcha's frame reads.** `chrome-demo.py --log-access` logs every
global and every navigator / screen / performance / document / canvas /
WebGL / audio member hCaptcha's frames read in Chromium: 253 distinct
items, every run the same. Checked one by one in the simulator, 60 are
missing here: WebGL and WebGL2 (getContext and 20 methods),
OfflineAudioContext / AudioBuffer / AnalyserNode (oscillator, compressor,
startRendering, getChannelData), the interface objects NavigatorUAData,
Permissions, NetworkInformation, StorageManager, SubtleCrypto,
DOMStringList, PerformanceResourceTiming, MediaSource, MediaRecorder,
OffscreenCanvas, RTCPeerConnection, SVGTextContentElement, Temporal;
navigator.plugins / mimeTypes / mediaDevices / keyboard /
webkitTemporaryStorage; performance.memory, screen.pixelDepth,
document.featurePolicy, window.caches / clientInformation / close /
speechSynthesis. (Against all of Chrome's window, 712 interfaces are
missing; hCaptcha reads these 60.)

**Each difference given to Chromium; it still gets the challenge:**

| Chromium given | getcaptcha answer |
|---|---|
| nothing (baseline) | challenge |
| all 60 missing items deleted (checked inside hCaptcha's frames) | challenge |
| its window cut to the engine's 486 globals (from 1230) | challenge |
| the engine's navigator and screen values (vendor "Anthropic/MPLS", product "MacSurf", 1 core, 1024x768, ...) and time zone (Etc/GMT-1) | challenge |
| requests to api.hcaptcha.com sent by a non-Chrome HTTP stack (Playwright's Node client, other TLS), sec-* headers dropped | challenge |
| a touch tap, or a click with no pointer movement before it | challenge |
| CPU throttled 4x and 12x | challenge |
| all of the above that combine (gap deleted, values, Node transport, touch) | challenge |

**And the engine is refused whoever it says it is:** the simulator with
the firefox preset and with its own `vita` user agent ("PlayStation Vita
3.65 ... NetSurf/3.12 VitaBrowser/0.1") gets the same 797-byte refusal.

**wasm3 is not miscomputing hsw's arithmetic** (as far as a differential
reaches): `wasm-diff/run.sh` exports hsw's 436 functions whose call trees
are import-free and calls each with the same seeded arguments in V8 and in
our wasm3 build: 426 identical in results, traps and a CRC of memory
after every call; the others all differ only where a garbage size made V8
grow memory to ~3 GB and wasm3 refuse. Random arguments mostly trap
early, so this covers less than hsw's real run does.

**So:** it is not hCaptcha disliking a non-Chrome browser -- not the
missing interfaces, not the values, not the user agent, not the network
layer, not speed. hsw computes something different in this engine (its
encrypted payload is 10-16 KB smaller), most likely one of its 182 glue
imports throwing or answering wrongly where Chromium does not, recorded
by hsw and refused by the server. Implementing the missing interfaces
would not move the result (Chromium without them passes). The next
measurement: trace hsw's import calls (name, arguments, result or
exception) in both engines and compare them in order.

## How to measure again

The scripts were scratch files; the method:

- **Chromium:** add an init script that wraps WebAssembly.instantiate,
  saves the bytes via `context.expose_binding`, and wraps every export
  with a performance.now() timer. It needs a non-"HeadlessChrome" user
  agent, or claude.ai serves no hCaptcha.
- **Opcodes:** a section and instruction walker over the code section.
- **Interpreter cost:** append exports for internal functions with
  import-free call trees, then time the same calls in Node and in a
  20-line wasm3 harness (all imports linked to a stub with
  m3_LinkRawFunction(..., NULL signature, ...)).
