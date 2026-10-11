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
   is a project of its own.
2. **WebAssembly with time slicing**: wasm3 behind a JS
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
