# VitaBrowser

A native, modern-ish web browser for a jailbroken PS Vita (enso/Henkaku).
**No server, no VPS, no proxy — the Vita fetches, parses, lays out, paints and
runs JavaScript itself.**

This document is the full project brief: research findings, the architecture
decision, and a phased build plan with acceptance criteria. It is written to be
self-sufficient — a developer (human or AI) should be able to start Phase 0
from this file alone.

---

## 1. Executive summary

- **Goal:** a browser that handles the modern web (HTML5, flexbox, grid,
  ES2023 JS, HTTPS with real CAs) and downloads files to the memory card,
  running 100% on-device.
- **Verdict: buildable in ~1–2 months** for one dev + AI assistance, because two
  projects have already done ~90% of the hard work on hardware *weaker* than the
  Vita:
  - **netsurf-3ds** — a working homebrew NetSurf browser for the Nintendo 3DS
    (ARM11, weaker than Vita's A9), active in Dec 2025. Proves the console
    frontend + toolchain shape.
  - **MacSurf** (2026) — the full NetSurf 5-lib engine + **QuickJS (ES2023)** +
    TLS 1.3 running natively on a 1998 Power Mac G3 (400 MHz, 128–192 MB RAM).
    Proves the engine + JS layer runs in Vita-class hardware, and gives us a
    CSS superset with hardware-verified fixes.
- **Chosen architecture:** MacSurf's engine (5 NetSurf core libs with its CSS
  fixes) + MacSurf's QuickJS bridge + netsurf-3ds's frontend architecture,
  re-targeted to vitaSDK (curl/openssl/freetype/harfbuzz/libvita2d).
- **Honest capability ceiling:** wikis, forums, news, WordPress, jQuery sites =
  great. `<video>`, `<canvas>`, WebGL, CSS animations, React-heavy SPAs = not
  supported (accepted trade-off; the stock WebKit-531 browser can't render the
  modern web at all, so anything is a win).
- **Expected speed:** simple pages 1–3 s, heavy pages 5–15 s on a ~333–533 MHz
  ARM9 core.

---

## 2. Hardware reality (PS Vita, PSP-1000/2000/3000)

| Spec | Value | Consequence |
|---|---|---|
| CPU | 4× ARM Cortex-A9, "1 GHz" marketing | Real clocks: ~333 MHz stock, ~533 MHz via homebrew clock app (VitaClock uses `scePowerSetArmClockFrequency`). Treat **333 MHz, 3 usable cores, NEON** as the design budget. |
| RAM | 512 MB DDR3, shared, **no userland paging** | OS + system services consume part; a homebrew app realistically gets **~200–330 MB**. No swap: a runaway page = crash. Profile memory from day 1. |
| GPU | PVR SGX543MP2+ | **OpenGL ES 2.0 only** (plus limited OpenVG). This alone kills Servo (WebRender needs GLES 3.0) and makes a 2D framebuffer (libvita2d) the right paint target. |
| Screen | Front 960×544 touch, rear 480×272 touch | 1:1 mapping front framebuffer → 960×544. Rear screen = free real estate for status/downloads. Dual analog sticks = great scroll/zoom. |
| Network | Wi-Fi (802.11 b/g/n) | Direct origin connections are fine; vita-sdk `curl` works out of the box. |
| Storage | Memory card, `ux0:/` user area | Downloads → `ux0:/download/` (standard location, file manager visible). |
| OS | VitaOS 3.75 + enso HEN (or Henkaku 3.65/3.68/3.75) | Homebrew NPXS apps install via pkg; no kernel mods needed for this project. |
| Debugging | No debugger | `printf` over UDP (host listens), vitaShell on-device, log files on `ux0:`. Budget ~1.5× dev time for the feedback loop. |

**Design rules that follow:**
1. Everything runs in-process (single-process browser). No multi-process —
   there's no `fork()`/process model in Vita userland.
2. Threads are fine (Vita userland is preemptively threaded, unlike OS 9), so
   fetch-on-worker-thread + paint-on-main-thread is safe.
3. All allocations are accounted: a page cache with hard caps, DOM tree
   garbage collected per navigation, image decode buffer reused.
4. 960×544 native — no DPI scaling. Fonts rasterized by freetype at 16 px base.

---

## 3. Research: what already exists

### 3.1 Prior art (all verified)

| Project | What it is | Why it matters |
|---|---|---|
| **Stock Vita browser** | WebKit 531 (2010, iPhone 4-era) | 2025 community tests: functionally dead on the modern web — no modern JS, most sites broken. This is the baseline we beat. |
| **DownloadEnabler** (XCage15, 2017, plugin by FloW) | TaiHEN/enso plugin patching the *stock* browser to download any file type to `ux0:/download` | Proves download-to-memorycard UX expectations; prior art for our download manager's behavior. |
| **UserAgentSpoofer** (GrapheneCt, 2022) | Plugin hooking the system `webcore`/`mini webcore` | Proves homebrew can hook the system WebKit — but that path is a dead end for modern web (531 ceiling). |
| **netsurf-3ds** (github.com/coderman64/netsurf-3ds, 197★, releases through Dec 2025) | Working homebrew NetSurf for the 3DS: libcss, libdom, libhubbub, libparserutils, libnsbmp/nsgif/svgtiny, libwapcaplet, libnsfb frontend, devkitPro toolchain, HTTPS (≤1.2) | **The console template.** Same architecture we need, on weaker hardware. Frontend patterns (framebuffer, input, app lifecycle, CI) transfer 1:1. |
| **MacSurf** (macsurf.org, github.com/mplsllc/macsurf, 2026, v2.0.5) | NetSurf port to Classic Mac OS 9 (PowerPC): all 5 core libs (443 files, ~125k lines, **C89-clean**), **macQJS = QuickJS ES2023**, macTLS = hand-rolled TLS 1.3 + TLS 1.2 fallback + 121 Mozilla CAs | **The engine + JS proof.** WordPress/jQuery 3.7 run with zero JS exceptions on 400 MHz/128 MB. Its C89-clean code compiles on any toolchain including vitaSDK. Its CSS fixes (grid V2, var(), aspect-ratio, font aliases) are a strict superset of upstream NetSurf. |
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
└── net (vita-sdk packages — replaces MacSurf's hand-rolled macTLS entirely)
    ├── curl (HTTP/1.1, redirects, keep-alive)
    ├── openssl (TLS 1.2/1.3, Mozilla CA bundle)
    └── libpng / libwebp / libjpeg-turbo / zlib (image decoding)
```

**Process model:** main thread = UI/layout/paint; worker threads = fetch + image
decode. No subprocesses. All engine code runs in-process.

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
- **Action:** record the chosen option in `LICENSE` before Phase 0 ends.
  Default assumption: **GPLv2+**.

---

## 6. Capability matrix (what v1 will / won't do)

| Works in v1 | Does not work in v1 |
|---|---|
| HTML5 parsing (libhubbub, full spec) | `<video>` / `<audio>` (no media pipeline) |
| CSS: block, inline, floats, tables, **flexbox, grid (V1/V2 per MacSurf status)** | `<canvas>`, WebGL, WebGPU |
| CSS: `var()` at cascade time, gradients, border-radius, text-shadow, opacity, background-clip, logical properties, aspect-ratio | CSS transitions/animations (queued, not v1) |
| **ES2023 JavaScript** (QuickJS): classes, async/await, modules dropped, template literals, arrow fns | `<script type="module">`, service workers |
| `fetch()` + async `XMLHttpRequest`, DOM mutation APIs (MacSurf set) | MutationObserver/ResizeObserver/IntersectionObserver (stubs), matchMedia |
| HTTPS 1.2/1.3, real Mozilla CAs, cookie jar, per-host UA | Heavy React/Vue SPAs (DOM API coverage limits) |
| PNG/WebP/GIF/JPEG images | HEIC/AVIF (add later; libheif not in vita-sdk yet) |
| **Downloads to `ux0:/download/`** with progress | — |
| Back/forward, bookmarks, history, multi-window (no tabs in v1) | — |

Performance expectations (333 MHz core, NEON): simple text pages 1–3 s;
typical WordPress/news page 3–8 s incl. sub-resources; very heavy pages
10–15 s; occasional 30 s+ on pathological CSS. Scroll/paint after load: 60 fps
trivial (framebuffer blit), reflow on resize: 10–50 ms typical.

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

Prove the toolchain + first libs + first pixels on the real device.

1. WSL2: install vitaSDK (`vdpm install`), build the printf example, install
   on the Vita via VitaShell, see host UDP logs. *(acceptance: log text appears
   on the host terminal from the Vita)*
2. Clone `refs/` codebases. Decide license (see §5.4) and record in `LICENSE`.
3. Cross-compile **libparserutils + libhubbub + libdom** for Vita (start from
   MacSurf's C89-clean versions; fix newlib/ARM build issues as they appear).
4. Fetch `https://example.com` with vita-sdk curl; parse it; walk the DOM.
5. Render the document's text (no CSS) to the libvita2d framebuffer with
   freetype.

**Phase 0 done = a real URL's text is on the Vita's screen, over HTTPS,
fetched natively.** If this slips past 3 weeks, stop and re-assess.

### Phase 1 — Core browser (weeks 3–8)

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
