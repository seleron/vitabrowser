# VitaBrowser

A native, modern-ish web browser for a jailbroken PS Vita (enso/Henkaku).
**No server, no VPS, no proxy — the Vita fetches, parses, lays out, paints and
runs JavaScript itself.**

This document is the full project brief: research findings, the architecture
decision, and a phased build plan with acceptance criteria. It is written to be
self-sufficient — a developer (human or AI) should be able to start Phase 0
from this file alone.

> **Findings live in [`docs/`](docs/).** [`docs/north-star.md`](docs/north-star.md)
> holds the end goal and its evidence-based blocker list;
> [`docs/phase-0/pre-phase-0-findings.md`](docs/phase-0/pre-phase-0-findings.md)
> holds the §14.11 checklist results. Where a findings doc contradicts this
> brief, **the findings doc is newer and wins.**
>
> **Read §13 and §14 first.** §§1–12 were written from research notes before
> the source projects were opened; §13 records what was checked on 2026-09-20
> and what turned out to be wrong, and §14 lists the decisions to settle before
> any code is written. Corrections are also applied in place above, marked with
> §13.x cross-references.

---

## 1. Executive summary

- **⭐ End goal (the north star):** **open `claude.ai/code` on the Vita and use
  it.** Everything else is a waypoint. v1 rendering only simple pages is an
  accepted and expected intermediate state — but v1 decisions must not
  foreclose the end goal. The evidence-based blocker list, and the five v1
  decisions that protect it, are in
  [`docs/north-star.md`](docs/north-star.md). *(This answers §14.1.)*
- **Goal:** a browser that handles the modern web (HTML5, flexbox, grid,
  ES2023 JS, HTTPS with real CAs) and downloads files to the memory card,
  running 100% on-device.
- **Verdict: buildable, but Phase 1 is months, not weeks** (see §14.10). Two
  projects have done most of the hard work on hardware *comparable* to the Vita
  — comparable, not weaker; see §13.1 before trusting any estimate here:
  - **netsurf-3ds** — an early (**v0.02**) homebrew NetSurf for the Nintendo 3DS,
    with **JavaScript disabled** and no file downloads. Proves the console
    frontend + toolchain shape, and nothing about running JS on a console.
  - **MacSurf** (2026, **v2.3**) — the full NetSurf 5-lib engine + **QuickJS
    (ES2023)** + TLS 1.3 running natively on a 1998 Power Mac G3 (400 MHz,
    128–192 MB RAM). Proves the engine + JS layer runs at Vita-class *clock
    speeds*, and gives us a CSS superset with hardware-verified fixes — but it
    wants more RAM than the Vita may be willing to give us (§13.1).
- **Chosen architecture:** MacSurf's engine (5 NetSurf core libs with its CSS
  fixes) + MacSurf's QuickJS bridge + netsurf-3ds's frontend architecture,
  re-targeted to vitaSDK (curl/openssl/freetype/harfbuzz/libvita2d).
- **Honest capability ceiling:** wikis, forums, news, WordPress, jQuery sites =
  great. `<video>`, `<canvas>`, WebGL, CSS animations, React-heavy SPAs = not
  supported (accepted trade-off; the stock WebKit-531 browser can't render the
  modern web at all, so anything is a win).
- **Expected speed:** simple pages 1–3 s, heavy pages 5–15 s on a ~333–533 MHz
  ARM9 core. **Treat these as unvalidated** — they were extrapolated assuming
  the Vita outruns a 400 MHz G3, which §13.1 shows is not clearly true.

---

## 2. Hardware reality (PS Vita, PSP-1000/2000/3000)

| Spec | Value | Consequence |
|---|---|---|
| CPU | 4× ARM Cortex-A9, "1 GHz" marketing | Real clocks: ~333 MHz stock, ~533 MHz via homebrew clock app (VitaClock uses `scePowerSetArmClockFrequency`). Treat **333 MHz, 3 usable cores, NEON** as the design budget. |
| RAM | 512 MB DDR3 + 128 MB CDRAM, **no userland paging** | **Measured from SDK docs 2026-09-20:** an app gets **MAIN 256 MiB by default, 365 MiB with the extended budget** (`-d ATTRIBUTE2=12` to `vita-mksfoex` at VPK build time), plus **CDRAM 112 MiB** (framebuffers — does *not* consume MAIN), PHYCONT 26 MiB, CDLG ~8 MiB. This clears MacSurf's 164 MB min / 195 MB preferred partition with headroom. No swap: a runaway page = crash. Still confirm on hardware (Phase 0 step 0). |
| GPU | PVR SGX543MP2+ | **OpenGL ES 2.0 only** (plus limited OpenVG). This alone kills Servo (WebRender needs GLES 3.0) and makes a 2D framebuffer (libvita2d) the right paint target. |
| Screen | Front 960×544 touch, rear 480×272 touch | 1:1 mapping front framebuffer → 960×544. Rear screen = free real estate for status/downloads. Dual analog sticks = great scroll/zoom. |
| Network | Wi-Fi (802.11 b/g/n) | Direct origin connections are fine; vita-sdk `curl` works out of the box. |
| Storage | Memory card, `ux0:/` user area | Downloads → `ux0:/download/` (standard location, file manager visible). |
| OS | VitaOS 3.75 + enso HEN (or Henkaku 3.65/3.68/3.75) | Homebrew NPXS apps install via pkg; no kernel mods needed for this project. |
| Debugging | No debugger | `printf` over UDP (host listens), vitaShell on-device, log files on `ux0:`. Budget ~1.5× dev time for the feedback loop. |

**Design rules that follow:**
1. Everything runs in-process (single-process browser). No multi-process —
   there's no `fork()`/process model in Vita userland.
2. **The engine runs on one thread.** Vita userland is preemptively threaded
   unlike OS 9 — but that is exactly why the engine is *not* thread-safe: it
   has never run anywhere threads existed, and NetSurf core is single-threaded
   by design. Use a single-threaded event loop with non-blocking `curl_multi`.
   Moving image decode off-thread is a later, isolated change behind a queue.
   (§13.3 — this rule was originally written backwards.)
3. All allocations are accounted: a page cache with hard caps, DOM tree
   garbage collected per navigation, image decode buffer reused.
4. 960×544 native — no DPI scaling. Fonts rasterized by freetype at 16 px base.

---

## 3. Research: what already exists

### 3.1 Prior art

*Originally labelled "all verified"; the netsurf-3ds and MacSurf rows were in
fact checked only on 2026-09-20, and both changed as a result — see §13.*

| Project | What it is | Why it matters |
|---|---|---|
| **Stock Vita browser** | WebKit 531 (2010, iPhone 4-era) | 2025 community tests: functionally dead on the modern web — no modern JS, most sites broken. This is the baseline we beat. |
| **DownloadEnabler** (XCage15, 2017, plugin by FloW) | TaiHEN/enso plugin patching the *stock* browser to download any file type to `ux0:/download` | Proves download-to-memorycard UX expectations; prior art for our download manager's behavior. |
| **UserAgentSpoofer** (GrapheneCt, 2022) | Plugin hooking the system `webcore`/`mini webcore` | Proves homebrew can hook the system WebKit — but that path is a dead end for modern web (531 ceiling). |
| **netsurf-3ds** (github.com/coderman64/netsurf-3ds, **v0.02**, releases through Dec 2025) | Early WIP homebrew NetSurf for the 3DS: libcss, libdom, libhubbub, libparserutils, libnsbmp/nsgif/svgtiny, libwapcaplet, libnsfb frontend, devkitPro toolchain, HTTPS (≤1.2). **JavaScript is disabled**; no file downloading; its own README says pages "may be mangled"; no WebP/SVG. | **The console template — for the frontend only.** Frontend patterns (framebuffer, input, app lifecycle, CI) transfer 1:1. It is *not* a working daily browser and proves nothing about running a JS engine in a console port (§13.2). |
| **MacSurf** (macsurf.org, github.com/mplsllc/macsurf, **v2.3 "OPEN TABS", 2026-09-19**) | NetSurf port to Classic Mac OS 9 (PowerPC): all 5 core libs (443 files, ~125k lines, **C89-clean** via CodeWarrior 8), **macQJS = QuickJS ES2023**, macTLS = TLS 1.3 + TLS 1.2 fallback + 121 Mozilla CAs, plus **`macLink/`** (Open Transport networking). Full source published. Requires **128 MB min / 256 MB recommended / 384 MB for heavy JS**. | **The engine + JS proof.** WordPress/jQuery 3.7 run with zero JS exceptions on 400 MHz/128 MB. C89-clean code compiles on vitaSDK. CSS fixes (grid V2, var(), aspect-ratio, font aliases) are a strict superset of upstream. **Caveat:** we discard *both* macTLS and macLink, and macQJS's async fetch/XHR are bound to macLink — so the JS bridge is not a clean lift (§13.2). |
| **NetSurf upstream** (netsurf-browser.org) | The canonical engine: MIT-licensed core libs, Duktape (ES5.1) JS engine | Upstream community and license, but **ES5.1 only** — the reason we prefer MacSurf's QuickJS variant for the JS layer. |
| **VHBB / Better Homebrew Browser** | Homebrew app stores (not web browsers) | Noted to avoid confusion in future research. |

### 3.2 Community sentiment (context)

- A May 2025 r/VitaPiracy thread ("why isn't anyone developing or porting a web
  browser for the vita", ~598 upvotes) confirms: demand is real, nobody has
  shipped it in 15 years, and the consensus answer is "too hard". One anonymous
  "I am working on it…" with no repo. **We are not duplicating any public work.**
- The same thread's technical comments match our findings: WebKit port =
  infeasible on this hardware; small native engine = the only path.

### 3.3 Why the alternatives were rejected

| Option | Effort | Why rejected |
|---|---|---|
| **Port WebKit (WPE/mini-WebKit)** | 12–24 months, ~25% success odds | WebKit2's multi-process architecture has no home on a Vita (no fork/AF_UNIX); ~70 MB minimum resident engine in a ~200–330 MB budget; PVR driver + GLES 2.0 surface for compositor; no community precedent on any handheld. |
| **Port Servo** | — | Dead on arrival: WebRender requires OpenGL ES 3.0; Vita has 2.0. |
| **Plugin on stock WebKit 531** | 2–8 weeks | Ceiling is 2010. You cannot polyfill CSS Grid/flexbox/ES6 into a 2010 engine. Would produce a slightly-better-old browser. |
| **Remote rendering (VPS + image/CDP stream)** | 6–10 weeks | *Was* the recommended plan v1, **rejected by user** (Vita must browse natively). MacSurf's history independently validates the rejection: it shipped a Go VPS proxy first, then abandoned it for a native TLS stack. |

---

## 4. Architecture

```
VitaBrowser — NPXS homebrew app (C, vitaSDK toolchain, single process)
│
├── frontend (NEW — modeled on netsurf-3ds's libnsfb frontend)
│   ├── TWO backends behind one plotter/fetch/fs abstraction (§14.2):
│   │     SDL-on-desktop (gdb/ASAN/valgrind) + libvita2d-on-Vita
│   ├── libvita2d framebuffer, 960×544 front screen
│   ├── sceCtrl + sceTouch: front touch = click/select, L/R sticks = scroll,
│   │   square/circle = back/forward, triangle = menu, rear screen = status bar
│   ├── freetype + harfbuzz text shaping (vita-sdk packages)
│   ├── OSK (on-screen keyboard) for URL entry
│   └── download manager: libcurl → ux0:/download/ with progress UI (rear screen)
│
├── engine (PORT — from MacSurf's tree, C89-clean)
│   ├── libparserutils  (entity/number/charset utilities, 15 files)
│   ├── libhubbub        (HTML5 parser, 30 files)
│   ├── libdom           (DOM tree + document, 95 files)
│   ├── libcss           (CSS parser + cascade + properties, 303 files,
│   │                     incl. MacSurf's grid V2 / var() / aspect-ratio fixes)
│   ├── libwapcaplet     (content-handling glue)
│   ├── html handler     (fetch → parse → DOM → cascade → layout → draw)
│   ├── layout engine    (block/inline/flex/grid/tables/floats → boxes)
│   └── plotters         (rects, gradients, round-rects, text, images → libvita2d)
│
├── JS (PORT — MacSurf's macQJS bridge)
│   ├── QuickJS (interpreted bytecode, no JIT — proven on PowerPC)
│   ├── DOM bindings (createTextNode, createDocumentFragment, innerHTML=, ...)
│   ├── async XMLHttpRequest + fetch() (mapped onto the fetch layer)
│   ├── RFC-6265 cookie jar, per-host User-Agent
│   └── known gaps to accept initially: matchMedia false, *Observer stubs,
│       <script type="module"> dropped, innerHTML reads as textContent
│
└── net (vita-sdk packages — replaces MacSurf's macTLS *and* macLink entirely;
    this is the seam where the QuickJS async fetch/XHR bindings must be
    re-hosted — original work, not porting. See §13.2)
    ├── curl (HTTP/1.1, redirects, keep-alive)
    ├── openssl (TLS 1.2/1.3, Mozilla CA bundle)
    └── libpng / libwebp / libjpeg-turbo / zlib (image decoding)
```

**Process model:** **single-threaded event loop.** UI, layout, paint, parse and
JS all run on one thread; fetching is non-blocking `curl_multi` pumped from that
same loop. No subprocesses, no worker threads touching engine structures — the
engine has no locking and has never run in a threaded context (§13.3). Image
decode may move to a worker later, in isolation, handing results back by queue.

**What deliberately does not exist:** `<video>`/`<audio>` (no media pipeline in
the NetSurf core), `<canvas>`/WebGL, CSS animations/transitions, service
workers. (Optional stretch: GStreamer exists in vita-sdk, so `<video>` is a
Phase 3+ idea, not v1.)

---

## 5. Engine base decision: NetSurf upstream vs MacSurf

MacSurf **is** NetSurf — it ports the same five core libraries. So the real
choice is which variant of the same engine to base on.

### 5.1 NetSurf upstream (netsurf-3ds model)

**Advantages**
- Active upstream + community; can merge upstream fixes; bigger test base
- netsurf-3ds is a proven console template (frontend, input, CI, release flow)

**Disadvantages**
- **JS engine is Duktape = ES5.1 only.** No classes, no async/await, no modern
  let/const. MacSurf retired Duktape for exactly this reason (1.68 release)
  and it required an ES6→ES5 transpiler that was *limited* — a lot of the
  "modern web" dies here.
- CSS support lags: the grid V2 placement work, cascade-time `var()`,
  aspect-ratio, font-family alias fixes are **not** upstream.
- The fb frontend is X11-flavored (libnsfb → X11), more rework than it looks.

### 5.2 MacSurf (mplsllc/macsurf)

**Advantages**
- **QuickJS ES2023 integrated and hardware-proven** — async fetch()/XHR, real
  DOM mutation, RFC-6265 cookie jar, per-host UA. This is the hardest 20% of
  the project and it's already done on hardware worse than the Vita.
- CSS strict superset (same libcss + two years of hardware-verified fixes).
- C89-clean throughout → compiles on vitaSDK with no language-level rework.
- Its own history validates the approach: started as a VPS-proxy browser,
  abandoned that, went fully native.
- Extensive documented bug history = a free lesson list (see §8).

**Disadvantages**
- Single maintainer, no community safety net.
- Frontend is 100% unusable (Carbon/QuickDraw for Mac OS 9) — discarded;
  true of any base, but means less frontend precedent than netsurf-3ds.
- No console-port precedent (desktop OS target, Open Transport networking).

### 5.3 Decision

**Hybrid, clean split:**
- Engine + CSS + JS bridge → **MacSurf's tree** (the 5 libs as fixed by
  MacSurf + macQJS integration).
- Frontend architecture → **netsurf-3ds** (framebuffer flow, input, lifecycle).
- Networking/fonts/paint → **vita-sdk packages** (curl, openssl, freetype,
  harfbuzz, libvita2d).

The JS bridge is the highest-value code in the project; it exists only in
MacSurf. That decides it.

**But be clear about what the hybrid does not inherit.** The two precedents do
not overlap at the seam we need: netsurf-3ds is a console frontend *with JS
disabled*, and MacSurf is a JS/CSS engine whose async I/O sits on a networking
layer (macLink) we are deleting. Nobody has connected a modern JS bridge to a
from-scratch console fetch layer. Budget that seam as original work (§13.2).

Vendor it as a **patch stack on upstream NetSurf**, not as a fork of MacSurf's
tree — see §14.4 for why.

### 5.4 Licensing (decision needed before vendoring)

- NetSurf core libs: **MIT**. QuickJS: **MIT**. vita-sdk packages: curl (MIT),
  openssl (Apache-2.0/OpenSSL), freetype (FTL/PDF), harfbuzz (MIT), libwebp
  (BSD) — all GPL-compatible.
- **MacSurf: GPLv2 (+ OpenSSL exception).** If we vendor MacSurf's *modified*
  libcss (with its grid/var fixes) or macQJS bridge code, the combined work is
  GPLv2 → **VitaBrowser ships as GPLv2+**.
- Options:
  1. **Accept GPL** (recommended for a homebrew project — fine for personal
     use and homebrew distribution; state the license in the repo).
  2. Keep the tree MIT-licensed by taking only *MIT-licensed upstream* code and
     re-implementing MacSurf's fixes (weeks of extra work, poor trade-off).
- **✅ RESOLVED 2026-09-20 — `LICENSE` written. The reasoning above was wrong;
  the conclusion was right.** A per-component audit found the five NetSurf core
  libs are **individually MIT** (own `COPYING` each), so vendoring MacSurf's
  modified libcss does *not* by itself force GPL. The GPLv2 comes from
  **`browser/netsurf`** — the HTML content handler, layout engine
  (`layout.c`/`layout_flex.c`/`layout_grid.c`) and plotters — which we cannot do
  without. **VitaBrowser ships GPLv2 + the OpenSSL linking exception**, which is
  mandatory for us (we link vita-sdk OpenSSL) and is already granted upstream.
  Corollary: core-lib fixes can still go upstream to NetSurf under MIT if kept
  free of GPL-derived code — so keep core-lib patches in a *separate series*
  from `browser/netsurf` patches. Full detail: `LICENSE`,
  `docs/phase-0/pre-phase-0-findings.md` §3.

---

## 6. Capability matrix (what v1 will / won't do)

| Works in v1 | Does not work in v1 |
|---|---|
| HTML5 parsing (libhubbub, full spec) | `<video>` / `<audio>` (no media pipeline) |
| CSS: block, inline, floats, tables, **flexbox, grid (V1/V2 per MacSurf status)** | `<canvas>`, WebGL, WebGPU |
| CSS: `var()` at cascade time, gradients, border-radius, text-shadow, opacity, background-clip, logical properties, aspect-ratio | CSS transitions/animations (queued, not v1) |
| **ES2023 JavaScript** (QuickJS): classes, async/await, template literals, arrow fns, **real ES modules** (`fixes1117b`) | service workers; **streaming responses — no SSE/EventSource, no WebSocket, XHR is completion-only** (the north-star blocker, see §13.5) |
| `fetch()` + async `XMLHttpRequest`, DOM mutation APIs, **real MutationObserver** (`fixes1235`), **real matchMedia** (`fixes1114b`), **real innerHTML read-back** (`fixes1168`) | IndexedDB, Cache Storage, FileReader, object URLs, Notifications (deliberately absent upstream); PerformanceObserver is a no-op; Resize/IntersectionObserver unverified |
| HTTPS 1.2/1.3, real Mozilla CAs, cookie jar, per-host UA | Heavy React/Vue SPAs (DOM API coverage limits) |
| PNG/WebP/GIF/JPEG images | HEIC/AVIF (add later; libheif not in vita-sdk yet) |
| **Downloads to `ux0:/download/`** with progress | — |
| Back/forward, bookmarks, history, multi-window (no tabs in v1) | — |

Performance expectations (333 MHz core, NEON): simple text pages 1–3 s;
typical WordPress/news page 3–8 s incl. sub-resources; very heavy pages
10–15 s; occasional 30 s+ on pathological CSS. Scroll/paint after load: 60 fps
trivial (framebuffer blit), reflow on resize: 10–50 ms typical.

**These numbers are unvalidated and probably optimistic.** They assumed the
Vita comfortably outruns MacSurf's 400 MHz G3; per-core that is not clearly
true (§13.1). They also assume no content blocking — with a fetch-layer
blocklist the realistic figures improve substantially, because on a CPU with no
crypto accelerator every extra origin costs a full software ECDHE handshake
(§14.5). Re-measure on hardware in Phase 0 and replace this paragraph.

---

## 7. Toolchain & Vita API cheat sheet

### 7.1 Toolchain

- **vitaSDK** (vitasdk.org): `vdpm` package manager, Linux-based (WSL2 is fine).
  `vdpm install` sets up the cross toolchain (arm-linux-gnueabihf, newlib).
- Packages to install (verify each with `vdpm search <name>`; the vita-sdk
  package set is the authoritative list):
  `curl`, `openssl`, `freetype2`, `harfbuzz`, `libpng`, `libwebp`,
  `libjpeg-turbo`, `zlib`, `libiconv`, `pcre`, `cjson` (bookmarks storage).
- App packaging: NPXS template (`vitasdk/examples`), sign with your dev cert,
  install as `.pkg` (VitaShell on-device, or `vap8k`/vita-pack tooling on host).
- Debug loop:
  1. `printf` → host: host runs `nc -ul <port>` and the app sends UDP logs
     (standard vitaSDK pattern, see `vitasdk/examples/printf`).
  2. vitaShell on the Vita: process list, memory, logs, files — the "SSH".
  3. Write state snapshots to `ux0:/app/<appid>/log.txt` for crash triage.

### 7.2 Key Vita APIs (frontend)

| Need | API |
|---|---|
| Framebuffer render | `libvita2d` (`v2d_*`, direct RGB565 960×544 front / 480×272 rear) |
| Input | `sceCtrlReadPadStateExtended`, `sceTouchPeekState` (front + rear) |
| System | `scePowerSetArmClockFrequency(533)` at startup (VitaClock does this) |
| Filesystem | `sceIoOpen/sceIoWrite` — `ux0:/download/` for downloads |
| Network | `sceNet*` + `curl` (vita-sdk curl handles AP settings via system) |
| Time/random | `sceKernelGetTick`, `sceRngRandom` (openssl needs seeding — use sceRng) |
| Dialogs/OSK | `sceAppUtilDialogLaunch` (OSK keyboard for URL entry) |
| Clock/date | `sceRtcGetCurrentClockLocalTime` |

### 7.3 Reference codebases (clone these in Phase 0)

```
refs/
├── netsurf-3ds/   (github.com/coderman64/netsurf-3ds)  ← frontend patterns
├── macsurf/       (github.com/mplsllc/macsurf)         ← engine + JS bridge
└── vita-sdk-examples/ (vitasdk.org examples)           ← app template, printf
```

---

## 8. Engineering lessons from MacSurf's documented bug history

These are real bugs found on real hardware — budget for them in Phase 1:

1. **Defensive clamps eat legitimate layout.** Their `html_redraw_box` had a
   ±10000 px "garbage" clamp that silently zeroed pages taller than 10000 px
   (4 debugging rounds to find). → When adding defensive bounds on Vita, use
   ±200000 and *log* every time a clamp fires.
2. **Width and paint must use identical font dispatch.** Their font-family
   alias bug (5 years old) manifested as "horizontal scrambling"; root cause
   was a clamp, not fonts — but the invariant (measure == paint font) is the
   one to enforce.
3. **Grid auto-placement with explicit placements needs an occupancy map**
   (per-row bitmap). The naive `i % n_tracks` mapping mis-assigns content
   the moment `grid-column`/`grid-row` placement appears. Port their
   fixes158a three-pass walker, not the naive version.
4. **U+00AD (soft hyphen)** paints phantom dashes at run boundaries; handle
   it in the line-breaker, not the font layer.
5. **Intrinsic sizing diverges from Chrome** for flex/grid/table without
   explicit dimensions — test against probe pages, not just happy paths.
6. **Adversarial test pages beat eyeballing.** Their whole CSS status is driven
   by "probe cards" (small numbered test pages, e.g. GP1-GP6, A1-A4, R1-R5)
   verified on hardware. Adopt the same discipline: `testpages/` in the repo,
   served from a local dir, each page = one property × edge cases.

---

## 9. Phased plan (with acceptance criteria)

### Phase 0 — De-risk spike (goal: ~1–2 weeks)

Prove the memory budget, the toolchain, the first libs, and first pixels — on
**both** backends. Steps 0 and 2a are new and gate everything after them.

0. **Measure the real Vita memory budget.** Write a minimal homebrew app that
   allocates until failure and logs the ceiling, in the budget class we intend
   to ship in. *(acceptance: a number, in MB, written into §2's RAM row,
   replacing the assumption.)* **This is the project's go/no-go input** — if
   the answer is near 200 MB, re-read §13.1 and reshape the plan before
   writing engine code.
1. WSL2: install vitaSDK (`vdpm install`), build the printf example, install
   on the Vita via VitaShell, see host UDP logs. *(acceptance: log text appears
   on the host terminal from the Vita)*
2. Clone `refs/` codebases. Decide license (see §5.4) and record in `LICENSE`.
2a. **Build MacSurf's five libs on desktop Linux first**, as a patch stack over
   upstream NetSurf (§14.4). Confirms C89-cleanliness for real, produces the
   verified diff of what MacSurf actually changed, and shows exactly what the
   JS bridge touches in the fetch layer. *(acceptance: libs build clean on
   desktop; `patches/` contains one documented patch per MacSurf fix.)*
3. Stand up the **plotter/fetch/fs abstraction with an SDL desktop backend**
   (§14.2), then cross-compile **libparserutils + libhubbub + libdom** for
   Vita; fix newlib/ARM build issues as they appear.
4. Fetch `https://example.com` with vita-sdk curl; parse it; walk the DOM.
5. Render the document's text (no CSS) to the framebuffer with freetype —
   desktop backend first, then libvita2d.

**Phase 0 done = (a) the memory ceiling is a measured number, and (b) a real
URL's text is on the Vita's screen, over HTTPS, fetched natively, from a
codebase that also renders it on the desktop backend.** If this slips past
3 weeks, stop and re-assess.

### Phase 1 — Core browser (**months, not weeks** — see §14.10)

6. Port the CSS cascade + layout engine (MacSurf's libcss + layout code),
   plotters re-targeted to libvita2d: rects, text, gradients, round-rects,
   images.
7. Images: PNG/WebP/GIF/JPEG decode (vita-sdk) → scaled blits.
8. QuickJS (macQJS) + DOM bindings + async XHR/fetch + cookie jar.
9. Downloads: libcurl → `ux0:/download/`, progress on rear screen, filename
   from Content-Disposition/URL.
10. Chrome: URL bar + OSK, back/forward, bookmarks (cjson file), history,
    menu, UA string.

**Phase 1 done = daily-driver-able for wikis, forums, news, WordPress,
jQuery sites. Downloaded file appears in the Vita's file manager.**
Gate: the MacSurf probe-card suite (grid, flex, fonts, line-breaking) passes
on-device.

### Phase 2 — Polish (ongoing)

11. Memory: hard page-cache caps, DOM GC per navigation, image buffer reuse,
    OOM crash triage with state snapshots.
12. CSS gaps per MacSurf's open queue, in their priority order: transform
    (Q1), two-value `gap` (Q2), `caption-side` (Q3), `table-layout: fixed`
    (Q4), multi-column (Q5).
13. Perf: NEON hot paths in the layouter, incremental reflow, lazy
    sub-resource fetch with priority (text first).
14. QoL: find-in-page, desktop UA toggle, per-site UA, download history.

### Phase 3 (stretch, explicit opt-in)

- `<video>` via GStreamer (vita-sdk package exists), AVIF/HEIC, tabs,
  reader mode, RSS, `matchMedia`/observers.

---

## 10. Risks & mitigations

| Risk | Mitigation |
|---|---|
| NetSurf DOM API coverage caps heavy JS SPAs | Accepted; v1 targets the non-SPA web. Document the list. |
| No media/canvas | Accepted; stock browser is worse. Phase 3 stretch. |
| Debug loop is slow (printf/UDP) | Phase 0 proves the loop early; keep a host-side DOM-dump tool (serialize libdom to XML, diff on host). |
| Memory pressure on big pages | Profile from Phase 0; hard caps; crash snapshots. |
| Single-maintainer upstream (MacSurf) | Vendor a pinned snapshot in `libs/`; re-apply upstream fixes by hand; track their repo. |
| Vita toolchain quirks (newlib, NEON codegen, PVR) | Phase 0 absorbs all of these before any feature work. |
| Scope creep toward "full modern web" | Capability matrix (§6) is the contract; anything not in it is Phase 3+. |
| ~~Memory ceiling below MacSurf's floor~~ — **DOWNGRADED** (§13.1) | Resolved 2026-09-20: 365 MiB MAIN + 112 MiB CDRAM, vs MacSurf's 195 MB preferred partition. Still manage it: cap the QuickJS heap hard, decode images to screen resolution, cap the page cache, framebuffers in CDRAM, content-block by default (§14.5). Confirm on hardware in Phase 0. |
| **No streaming transport** (§13.5) — *blocks the north star* | **Now the highest-severity risk to the end goal.** No SSE/WebSocket; XHR is completion-only. Mitigation is a v1 decision, not later work: build the fetch layer on `curl_multi` with an incremental write callback from day one, then expose `readyState 3`/`onprogress`/`EventSource`. Never copy `macos9_js_fetch.c`'s completion-only model. |
| **Core libs not separable from MacSurf's platform layer** (§13.6) | 55 core-lib files include MacSurf headers. Patch stack (§14.4) makes them visible up front instead of one compile error at a time. Port `macsurf_alloc_override.h` deliberately — we want allocation accounting anyway (§2 rule 3). |
| Port is ~40% larger than scoped (§13.6) | 864 files / ~173k lines, not 443 / ~125k. Does not change the architecture; does change the schedule. Reflected in §14.10. |
| **The JS-bridge ↔ fetch-layer seam is unprecedented** (§13.2) | Treat as original work, not porting. Schedule it early in Phase 1 while there is still slack, not last. |
| **Engine is not thread-safe** (§13.3) | Single-threaded event loop (§4). Never move engine structures onto a worker. |
| Debugging a 125k-line C port with no debugger | Desktop backend takes the majority of this load (§14.2); golden-image diffing catches regressions (§14.3). |
| Runaway script hangs a device with no task manager | `JS_SetMemoryLimit` + `JS_SetInterruptHandler` wired on day one (§14.7). |
| MacSurf upstream moves faster than we track | It shipped v2.3 one day after this brief cited v2.0.5. Patch stack (§14.4) makes re-basing mechanical instead of archaeological. |

---

## 11. Conventions

- **One item → one branch → one PR.** No mixed gate+feature branches.
- C (C11 for new frontend code; engine libs stay C89-clean).
- `app/` = frontend + app, `libs/` = vendored engine (pinned snapshots),
  `testpages/` = probe cards, `docs/` = research notes.
- Commits reference the probe page they fix when relevant (e.g. "fix grid
  track sizing — GP4/GP5 pass").
- Hardware verification is the definition of done; "compiles" is not.

---

## 12. Reference links

- netsurf-3ds: https://github.com/coderman64/netsurf-3ds (releases, WIP thread: gbatemp.net/threads/wip-release-netsurf-3ds.649398)
- MacSurf: https://macsurf.org (architecture, css.html = full CSS status,
  history.html = release-by-release, github.com/mplsllc/macsurf)
- NetSurf: https://www.netsurf-browser.org (MIT core)
- QuickJS: https://bellard.org/quickjs/ (MIT)
- vitaSDK: https://vitasdk.org (packages, examples)
- enso HEN: https://github.com/sleirsgo/homebrew 3.75 (Vita jailbreak)
- Prior art: DownloadEnabler (github.com/XCage15/DownloadEnabler),
  UserAgentSpoofer (github.com/GrapheneCt/UserAgentSpoofer)
- Vita clock: VitaClock (homebrew) — `scePowerSetArmClockFrequency`
- Community: r/vitahacks, r/VitaPiracy, vita.dl on Discord

---

## 13. Verification record (2026-09-20)

§§1–12 were written from research notes without opening the source projects.
On 2026-09-20 the two load-bearing precedents were checked against their
published sources. **Three claims did not survive.** The affected text above
has been corrected in place and cross-references this section; where anything
earlier still conflicts with what follows, this section wins.

Both projects are real, both publish full source, and the core bet — that a
NetSurf-derived engine plus QuickJS fits on Vita-class hardware — survives.
What changed is *which axis is hard*.

### 13.1 Memory — feared binding constraint, since resolved

The brief's framing was that MacSurf proves the engine runs on hardware
"weaker than the Vita." That holds on clock speed and fails on memory.

MacSurf's own architecture page states its requirements: **128 MB minimum,
256 MB recommended, 384 MB for heavy JavaScript**, with an application
partition of **164 MB minimum / ~195 MB preferred**.

Our assumed Vita budget is ~200–330 MB — and that has to cover MacSurf's
partition *plus* libvita2d framebuffers, curl + OpenSSL, freetype/harfbuzz
caches, image decode buffers and the QuickJS heap. MacSurf's *preferred*
partition alone consumes the bottom of our entire assumed budget.

On CPU the margin is also thinner than claimed: a 400 MHz PowerPC G3 against a
333 MHz Cortex-A9 is roughly **comparable per-core**, not clearly worse. Every
speed estimate in §1 and §6 was extrapolated from "Vita > G3" and is therefore
optimistic by an unknown factor.

**✅ UPDATE 2026-09-20 — resolved favourably; this risk is downgraded.** The
budget was looked up rather than guessed: an app gets **MAIN 256 MiB by
default and 365 MiB with the extended budget** (`-d ATTRIBUTE2=12` passed to
`vita-mksfoex` at VPK build time — a packaging flag, not a code change), plus a
**separate 112 MiB CDRAM pool** for framebuffers. Two errors in the original
worry: the ceiling is roughly double what was assumed, and framebuffers were
double-counted — they live in CDRAM, not MAIN. 365 MiB clears MacSurf's 195 MB
preferred partition with ~170 MB of headroom and approaches its 384 MB heavy-JS
figure.

Memory therefore drops from "possible showstopper" to "a budget to manage."
Phase 0 step 0 remains, but as *confirmation* (does `ATTRIBUTE2=12` work on
3.75 + enso? what is real headroom after fragmentation?) rather than as a
go/no-go gate. Detail: `docs/phase-0/pre-phase-0-findings.md` §1.

### 13.2 The two precedents do not overlap at the seam we need

- **netsurf-3ds is v0.02 with JavaScript disabled**, no file downloading,
  TLS 1.2 only, and its own README warns pages "may be mangled." It is a real
  console-frontend precedent. It is not a working browser, and it demonstrates
  nothing about running a JS engine in a console port.
- **MacSurf** proves the JS and CSS half — but its repo contains **`macTLS/`
  and `macLink/`** (Open Transport networking), and our plan deletes both.
  macQJS's highest-value features, async `fetch()` and `XMLHttpRequest`, are
  bound to that fetch layer.

So the hybrid's seam — a modern JS bridge re-hosted on a from-scratch console
fetch layer — is the one piece **neither precedent has done**. It is the
highest-uncertainty work in the project and must be budgeted as original
engineering, not as porting, and scheduled early in Phase 1 rather than last.

### 13.3 The threading model was backwards

§2's original design rule 2 read: "Threads are fine (Vita userland is
preemptively threaded, unlike OS 9), so fetch-on-worker-thread +
paint-on-main-thread is safe." §4 built a process model on it.

Invert the reasoning. **Mac OS 9 has no preemptive threading** — which means
MacSurf's ~125k lines have never executed anywhere threads existed and almost
certainly contain no locking whatsoever. NetSurf core is single-threaded by
design. Threads being *available* on the Vita is not the same as the engine
being *safe* in them; the plan as written would have introduced data races
into a codebase we did not write, on a platform with no debugger, no ASAN and
no TSan.

Corrected in §2 (rule 2) and §4 (process model): single-threaded event loop,
non-blocking `curl_multi`.

### 13.4 Smaller corrections

- MacSurf is at **v2.3 "OPEN TABS" (2026-09-19)**, not v2.0.5 — the brief was
  stale within a day of being written. Assume this upstream moves fast.
- **The C89-clean claim is false — and irrelevant.** Verified by compiling:
  under `gcc -std=c89 -pedantic`, libwapcaplet is 0/1 clean, libparserutils
  7/15, libhubbub 4/32. The failures are C99 `static inline` and `restrict`,
  present in *upstream* NetSurf, not introduced by MacSurf. Every one of those
  files compiles clean in GCC's default mode, which is what vitaSDK uses. So
  C89-cleanliness is worth even less than §5.2 implies — the real value of
  MacSurf is the CSS fixes and the QuickJS bridge, not the dialect.
- macTLS is described as hand-written TLS 1.3 (RFC 8446, X25519/ECDHE) in one
  source and as BearSSL-based in another. Moot for us — we use OpenSSL — but a
  reminder that secondary descriptions of this project drift.
- MacSurf ships `harness/`, `tests/`, `perf/` and `screenshots/` (hardware
  captures). Their test methodology is worth adopting wholesale (§14.3).

### 13.5 The JS gap list in §6 was stale — the end goal is more reachable than stated

Audited against MacSurf's bridge source (16,803 lines) rather than its docs.
**Four of the five gaps §6 listed as permanent have been fixed upstream:**

| §6 claimed | Actually |
|---|---|
| `<script type="module">` dropped | **Real ES modules** — `fixes1117b (#265)`, `JS_SetModuleLoaderFunc` + `JS_EVAL_TYPE_MODULE`; `html/script.c:1245` dispatches inline *and* external module scripts |
| matchMedia false | **Real evaluator** — `fixes1114b (#265)` |
| innerHTML reads as textContent | **Real HTML serializer** — `fixes1168 (#262)` |
| *Observer stubs | **MutationObserver is real** — `fixes1235 (#167)`, delivers actual `addedNodes`. PerformanceObserver is still a no-op; Resize/Intersection unverified |

**The real remaining blocker is streaming transport**, which §6 never mentioned:
no `EventSource`, no WebSocket, and `macos9_js_fetch.c:314` sets `readyState`
straight to `4` — responses are all-or-nothing. That is fatal for a token-
streaming UI, and it is *also* the most fixable, because it is an artefact of
the Open Transport layer **we are replacing with `curl_multi` anyway**.

Full analysis and the v1 decisions that follow: [`docs/north-star.md`](docs/north-star.md).

### 13.6 The port is bigger, and less separable, than §3.1 claimed

Measured over `src/` + `include/`, excluding tests:

| | §3.1 claimed | Actual |
|---|---|---|
| Core-lib files | 443 | **864** |
| Core-lib lines | ~125k | **~173k** |

And the libs are **not cleanly separable**: **55 files inside the five
"portable" core libraries include MacSurf platform headers** (e.g.
`libdom/include/dom/functypes.h` pulls `macsurf_alloc_override.h`, which lives
in `frontends/macos9/`). Lifting the tree wholesale imports 55 hidden platform
dependencies, discovered one compile error at a time.

Also confirmed: **the JS bridge lives in the frontend**, not shared engine code
— `frontends/macos9/javascript/` is 19,084 lines, of which `macos9_js_fetch.c`
(852) is directly networking-coupled. And `frontends/` does contain
**`framebuffer`** (10,107 lines — our starting point) and **`monkey`** (3,174
lines — headless, the test backend), confirming §14.2 and §14.3 are structural,
not inventions.

These three findings together make §14.4's patch-stack **urgent rather than
advisable.**

### 13.7 Sources

- MacSurf architecture: https://macsurf.org/architecture.html
- MacSurf story/history: https://macsurf.org/story.html
- MacSurf repo: https://github.com/mplsllc/macsurf
- netsurf-3ds README: https://github.com/coderman64/netsurf-3ds/blob/main/README.md
- netsurf-3ds on GameBrew: https://www.gamebrew.org/wiki/Netsurf_3DS
- Hackaday coverage: https://hackaday.com/2026/05/29/a-modern-web-browser-for-classic-mac-os/
- Vita memory budgets: https://vita-rust.github.io/book/dev/mem.html
- vitaSDK sysmem API: https://docs.vitasdk.org/kernel_2sysmem_8h_source.html
- §§13.4/13.5/13.6 primary evidence: `mplsllc/macsurf` @ `55e64fa` (v2.3,
  2026-09-19), audited locally — see
  [`docs/phase-0/pre-phase-0-findings.md`](docs/phase-0/pre-phase-0-findings.md)

---

## 14. Strategy: settle these before Phase 0

### 14.1 The goal question — what is this actually for?

**This is the one decision that changes everything else, and it is not yet
written down anywhere in this brief.**

§6 already concedes the honest ceiling: wikis, forums, news, WordPress,
jQuery. No SPAs, no canvas, no video. Given that ceiling, there are two
legitimate goals and they want different projects:

- **"I want to read the web on my Vita."** Then a **native reader** — fetch,
  extract article content on-device, render clean text and images — delivers
  most of the real-world value for a small fraction of the effort, and stays
  fully compatible with the no-proxy constraint at the top of this file
  (which is a *value*, not an engineering conclusion — see §3.3's v1
  rejection). The engine port is then optional, not required.
- **"I want to build a browser."** Porting a real engine to a locked-down 2011
  handheld is the interesting thing in its own right. Entirely legitimate —
  but then say so here, because it changes how to read the rest: the timeline
  stops mattering, §9's Phase 0 abort gate becomes the only gate that matters,
  and effort spent on hard problems is the point rather than a cost.

### ✅ ANSWERED 2026-09-20

**The goal is to open `claude.ai/code` on the Vita and use it.** The browser is
the chosen path; v1 rendering only simple pages is an accepted waypoint. The
reader alternative above was considered and **rejected by the owner**.

Recorded in §1. This resolves §14.1 and anchors §10's scope-creep mitigation:
**the capability matrix is the v1 contract; the north star is the direction of
travel.** Anything that is neither in §6 nor on the path in
[`docs/north-star.md`](docs/north-star.md) is out.

An evidence-based audit of what still stands between v1 and that goal — and the
**five v1 decisions that keep it reachable** — is in
[`docs/north-star.md`](docs/north-star.md). The most important of them, because
it is the only blocker whose cost is set by a decision *we* make now:
**build the fetch layer streaming-first on `curl_multi`, never completion-only**
(§13.5).

### 14.2 Build the desktop backend first

The largest single change to the plan as written.

NetSurf already has a frontend abstraction with several backends, including a
headless one built for automated testing. Write our plotter/fetch/filesystem
layer against that abstraction with **two** backends from day one:

- **SDL-on-desktop** — full speed, gdb, ASAN, valgrind, instant iteration.
- **libvita2d-on-Vita** — the ship target.

Then engine bring-up, CSS bugs, layout bugs and JS-bridge bugs are debugged on
a workstation, and only genuinely platform-specific failures — memory ceiling,
newlib quirks, NEON codegen, alignment — need the Vita and its UDP-printf
loop. §2 budgets 1.5× dev time for the Vita feedback loop; this is how that
multiplier gets paid down. Cost: a few days. Reflected in §9 step 3.

### 14.3 Golden-image diffing is the test strategy

Falls directly out of §14.2, and is the highest-leverage tooling in the
project: render a probe page on the desktop backend, dump the Vita's
framebuffer to `ux0:` as PNG, diff host-side.

That yields a real regression suite for a browser engine on a platform with no
debugger. Combine with §8's probe-card discipline (`testpages/`), served from
a local directory or from `ux0:` so tests don't depend on Wi-Fi. MacSurf
already has `harness/`, `tests/`, `perf/` and `screenshots/` — adopt their
methodology rather than inventing one.

### 14.4 Vendor a patch stack, not a fork

§10 currently mitigates single-maintainer risk with "pin a snapshot in
`libs/`." Do better: vendor **upstream NetSurf** and apply MacSurf's changes
as a **documented patch series** in `patches/`.

Three payoffs:
1. It forces us to read and verify every fix this brief asserts exists —
   which, per §13, is not a theoretical concern.
2. It makes tracking a fast-moving upstream mechanical instead of
   archaeological (MacSurf shipped v2.3 one day after we cited v2.0.5).
3. Licensing becomes legible per-patch rather than per-tree.

**One-way door to note:** once GPLv2 code is vendored, our Vita fixes cannot be
contributed back to MIT-licensed upstream NetSurf. §5.2 lists "can merge
upstream fixes" as an upstream advantage; that flow becomes one-directional.

### 14.5 Content blocking is architecture, not polish

On a 333 MHz ARM with no crypto accelerator, **every additional origin costs a
full software ECDHE handshake**, and a typical news page pulls dozens of
subresources across many hosts. A fetch-layer blocklist is plausibly a **2–5×
page-load win and a large memory saving**.

On this hardware that is not a QoL feature — it is load-bearing architecture,
and it belongs in Phase 1 next to the fetch layer, not in §9's Phase 2 "QoL"
bucket. It also changes §6's performance numbers for the better.

### 14.6 Solve URL entry without the OSK

Text entry is the single most frequent interaction in a browser and the Vita
OSK is miserable. §4 gives input two lines; the UX consequences deserve more.

Cheap fix: run a **tiny HTTP listener on the Vita** so a URL can be pushed
from a phone or PC on the same LAN. Sidesteps the worst interaction in the
product for the common case. A bookmarks-first launch screen covers the rest.
Dual analog sticks and the rear touchpad are genuine advantages over every
other console browser — design for them rather than treating them as a
mapping problem.

### 14.7 Runaway-script protection on day one

Wire `JS_SetMemoryLimit` and `JS_SetInterruptHandler` when QuickJS is first
integrated, not later. Without them a single `while(1){}` on a page hangs a
device with no task manager, no OOM killer and no way out but the power
button. This is a month-three bug preventable in hour one.

### 14.8 Ship the chrome last

§9 item 10 (URL bar, back/forward, bookmarks, history, menu) is roughly 30% of
Phase 1's calendar and roughly 0% of its risk. v0 should be: a URL, a page,
back/forward on hardware buttons, and a bookmarks **text file** on `ux0:`.
Everything else moves behind the first hardware-verified page render.

### 14.9 Default zoom is a real decision

§2 design rule 4 says "960×544 native — no DPI scaling, 16 px base." The Vita
panel is roughly 220 PPI, so 16 px will be physically tiny.

Make zoom a **first-class, tuned parameter** from the start. It touches
layout, font cache memory and image scaling, so retrofitting it is painful.
Pick the default empirically on hardware in Phase 0, at the same time as the
memory measurement.

### 14.10 Timeline honesty

**"~1–2 months for one dev + AI assistance" was off by several times** for
Phase 1 as scoped, and has been removed from §1.

- **Phase 0 at 1–2 weeks: realistic** (plus step 0's measurement day).
- **Phase 1: months, not weeks.**

The estimate being wrong does not threaten the project. An *unacknowledged*
wrong estimate threatens morale around week 10, which is how hobby projects
actually die. §9's 3-week Phase 0 abort gate is good practice — keep it, and
hold to it.

### 14.11 Pre-Phase-0 checklist

1. **Measure the real Vita memory budget** for a homebrew app in the target
   budget class. Write the number into §2's RAM row. Gate everything on it.
   (§13.1)
2. **Clone both refs and build MacSurf's five libs on desktop Linux.** Confirms
   C89-cleanliness, produces the upstream-vs-MacSurf diff, and reveals what the
   JS bridge actually touches in the fetch layer. (§13.2, §14.4)
3. **Answer §14.1** and write the goal into §1.
4. **Decide GPLv2+ and write `LICENSE`.** Five minutes; don't let it linger.
   (§5.4)
5. **Delete the empty `client/` directory** — a holdover from the rejected VPS
   plan, and inconsistent with §11's layout.

**✅ EXECUTED 2026-09-20** — full record in
[`docs/phase-0/pre-phase-0-findings.md`](docs/phase-0/pre-phase-0-findings.md).

| # | Item | Status |
|---|---|---|
| 1 | Measure memory budget | **Documented:** 365 MiB MAIN (extended) + 112 MiB CDRAM. Risk downgraded (§13.1). On-hardware confirmation → Phase 0 step 0 |
| 2 | Clone refs, build libs on desktop | **Audited.** Sizes, licences, coupling and compile behaviour characterised (§13.4, §13.6). Full build blocked on the NetSurf buildsystem → Phase 0 |
| 3 | Answer §14.1, write goal into §1 | **Done** (§14.1 above, §1) |
| 4 | Decide licence, write `LICENSE` | **Done.** GPLv2 + OpenSSL exception (§5.4) |
| 5 | Delete empty `client/` | **Done** |

The checklist did what it was for: it either de-risked the plan or reshaped it
at zero sunk cost. Outcome — **both top risks moved in our favour** (memory
§13.1, JS capability §13.5) while the port turned out **larger and less
separable** than claimed (§13.6).

### Next actions (Phase 0 proper)

1. **Install vitaSDK**, build the printf example, confirm the UDP log loop.
   Blocks everything on-device.
2. **Stand up the NetSurf buildsystem** on desktop; get libcss + libdom
   generating and compiling. This is the real gate — both need generated
   sources (`mkprops.pl`, libdom bindings) plus the MacSurf headers from §13.6.
3. **Produce the upstream-vs-MacSurf diff** and start `patches/` (§14.4).
   §13.6 makes this urgent.
4. **Confirm `ATTRIBUTE2=12`** on 3.75 + enso, then run the allocation probe.
