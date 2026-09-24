# 11 — Real websites, end to end

**Task:** make real websites load end to end on the Vita:
- example.com over http first;
- then a heavier real page over https (English Wikipedia);
- DNS, TLS, layout, JavaScript, fetch/XHR and memory on the live network.

**Method:** verify in the simulator first. `nsvita-sim` is the Vita frontend and engine with the Vita's curl +
mbedTLS, DNS on the resolver's worker thread (patch 49), QuickJS and
MacSurf's bridge, against the live internet. Stage a device hand-off only
for something device-specific.

**Status (2026-09-24, round 2 added):** SVG, mask-image icons and
`background-size` fixed (patches 59–61, "Round 2" below).

**Round 1 status:**
- example.com (http), English Wikipedia (https, article and main page),
  Hacker News, CNN Lite and a DuckDuckGo Lite search all load and lay
  out.
- Three engine/frontend root causes found and fixed (patches 55–57).
- The patch-58 section below lists the gaps left.

## The tool

`tools/run-live-sites.sh`: each site in the simulator, over the live
network, reporting:
- when the document arrived;
- its extent and title;
- hosts blocked (patch 52);
- peak memory (host RSS of a 64-bit process, so an upper bound for the
  Vita's 32-bit one);
- a screenshot once settled.

It fails if a page gets no document or no title. It needs the internet,
so it is not part of `tools/run-vita-sim.sh`; the clean-checkout chain
runs it after the simulator.

Two simulator changes support it:
- `VITA_SIM_MIN_MS` (tools/vita-sim) gives each page a minimum time
  before it may count as settled. A live page draws nothing while it
  loads, so the simulator's screenshot mode called Wikipedia settled
  after 1.3 s, before its document came.
- The autotest's `nettest.txt` now takes up to 16 pages (patch 58; it
  silently ignored more than 8).

## Root causes found and fixed

### 1. The user agent said "Linux desktop" (patch 55)

- NetSurf sent `Mozilla/5.0 (X11; Linux) NetSurf/3.12`.
- Wikipedia now serves every client from one domain: `en.m.` answers
  301 to `en.wikipedia.org`, even for real phones (checked with Android
  and iPhone user agents). It picks the skin by user agent, so we got
  desktop Vector: a 1032-px-wide page on a 960 × 544 screen.
- JavaScript meanwhile saw `MacSurf/2.3 (Macintosh; PPC Mac OS 9)`,
  MacSurf's hard-coded navigator: two different browsers.

The fix:
- **HTTP:** the core's `NETSURF_UA_FORMAT_STRING` hook, in
  `frontends/vita/Makefile.defaults`:
  `Mozilla/5.0 (PlayStation Vita 3.65) AppleWebKit/537.73 (KHTML, like Gecko) Mobile NetSurf/3.12 VitaBrowser/0.1`.
  (`%.0s` swallows the uname sysname the core formats in.)
- **JavaScript:** `navigator.userAgent` and `appVersion` read the same
  string, and `platform` is "PlayStation Vita".
- **Result:** Wikipedia serves its mobile Minerva skin.

### 2. Body's overflow did not go to the viewport (patch 56)

- **CSS 2.1 §11.1.1:** the root element's `overflow` applies to the
  viewport, and so does the body's when the root's is `visible`. The
  element itself then behaves as `overflow: visible`.
- **NetSurf** gave body's `overflow` to the body box. Upstream NetSurf has
  the same gap.
- **The failure:** Minerva has `html, body { height: 100% }` and
  `body { overflow-y: scroll }`. So the body became a scroll box one
  viewport high, holding the whole article: the extent was 1011 × 544,
  with a scrollbar inside the page. The Vita window, whose scrolling is
  the page's, could not reach anything below the first screen.
- **Minimal case** (`CSS-overflow-viewport.html`): exactly those two rules
  plus 60 paragraphs gave 960 × 544. Variants with `overflow-x: hidden`,
  or `height: 100%` alone, were already right.

**The fix:**
- A box flag, `OVERFLOW_TO_VIEWPORT`, is set at the start of every
  layout on the root, and on `<body>` when the root's `overflow` is
  `visible`.
- `box_overflow_x/y()` give the *used* value (`visible` for a flagged
  box).
- All 21 `css_computed_overflow_[xy](box->style)` reads in `layout.c`,
  `redraw.c` and `box_inspect.c` go through them. The float-dimension
  helper, given a style rather than a box, is left alone.

**Result:** the minimal case is 960 × 2280, and Wikipedia's article is
one page, 1011 × 25 076.

### 3. A space leading an inline element's text vanished (patch 57)

- **The failure:** "Claude discovers … repeats(anthropic.com)" on every
  Hacker News row. The markup is `<a>Title</a><span class="sitebit"> (<a…>`.
- **The mechanism:** `box_construct_text` strips a text box's leading
  space and gives it to the box before it (`prev->space`). After
  `</a><span>`, that box is the span's `BOX_INLINE` start marker, and
  `layout_line` ignored `space` on inline start boxes in both passes, as
  did `layout_minmax_line` in the widths. Upstream has the same code.
- **The fix:** an inline start box's `space` counts like an inline end's,
  measured in the inline's own font.
- **Minimal case** (`CSS-inline-space.html`): the second word lands at
  the same x with the space inside or outside the element.
  `run-vita-sim.sh` checks this from the plot dump.

## Results on the live network

From the clean-checkout chain (patches 1–58), 2026-09-24. Times are the
simulator's on the build PC's connection, so they're a lower bound for
the Vita (run 11: example.com took 0.9 s on the device, http, and 1.4 s
over https).

| site | document after | extent | blocked | host RSS | title |
|---|---|---|---|---|---|
| http://example.com/ | 245 ms | 960 × 544 | 0 | 17 MB | Example Domain |
| https://en.m.wikipedia.org/wiki/PlayStation_Vita | 2 320 ms | 1011 × 25 076 | 0 | 76 MB | PlayStation Vita - Wikipedia |
| https://en.wikipedia.org/wiki/Main_Page | 2 351 ms | 985 × 4 349 | 0 | 47 MB | Wikipedia, the free encyclopedia |
| https://news.ycombinator.com/ | 1 403 ms | 960 × 1 301 | 0 | 25 MB | Hacker News |
| https://lite.cnn.com/ | 577 ms | 960 × 3 641 | 0 | 25 MB | Breaking News, Latest News and Videos \| CNN |
| https://lite.duckduckgo.com/lite/?q=playstation+vita | 1 002 ms | 960 × 1 746 | 0 | 25 MB | playstation vita at DuckDuckGo |

What each layer did on the Wikipedia article:
- **DNS:** four hosts (en.m, en, thumb.wikimedia, upload.wikimedia),
  each resolved on the worker in 10–55 ms, with 41 cache hits.
- **TLS:** every fetch over https with mbedTLS against the bundled
  Mozilla roots; 51 fetches (the page, 5 stylesheets / modules, about 40
  images).
- **JavaScript:** MediaWiki's ResourceLoader ran. Its startup module
  fetched further modules through script insertion (`load.php?modules=…`
  gadgets, centralNotice), and the bridge drove its script-driven
  relayouts (379 reconvert steps). There were **no script exceptions in the
  log**.
- **Layout:** the Minerva skin with flex headers, the infobox with its
  images, and tables.

![Wikipedia on the simulator, patches 1–58](img/11-real-sites/wikipedia-article.png)
![Hacker News](img/11-real-sites/hacker-news.png)

## Round 2: SVG, masks, background-size (patches 59–61)

### 4. SVG images (patch 61, tools/build-vita.sh)

- **The Vita prefix:** expat 2.8.4 from vdpm
  (`~/vitasdk/bin/vdpm install expat`: vitaSDK's own vdpm, no sudo).
  The checkout under `<WORK>/vitabrowser-work/vdpm` wants a pacman it doesn't
  have.
- **libdom** is built `WITH_EXPAT_BINDING=yes`, its XML parser, which
  libsvgtiny uses.
- **libsvgtiny** is cross-built with the other support libraries.
- `NETSURF_USE_NSSVG := YES`.
- **The simulator** links the host prefix's libsvgtiny, which the host
  build already had.
- **Verified** with `IMG-svg.html`: an `<img>` logo (a rect, a stroked
  path, a circle, a polygon, scaled 120×40 → 240×80), a CSS background
  icon, and a `background-size`d one. The first two are in the screenshot
  below. `run-vita-sim.sh` asserts ≥ 5 paths drawn and no alt text.
- **Live:** Hacker News's "Y" logo draws, with 0 SVGs refused (there were
  658 refusals on Wikipedia before).
- **The Vita build** links libsvgtiny and expat (`svgtiny_*`,
  `XML_Parse*` in the ELF).

![SVG](img/11-real-sites/svg.png)

### 5. background-size never applied (patch 59, libcss)

**Found through the mask icons**, whose size is a `background-size`:
- a 12 px SVG icon given `background-size: 48px` drew at 12 px;
- then a PNG given the same didn't scale either (it was only clipped to
  its box);
- `nsmonkey` agreed. So the bug was in the engine, not the Vita
  plotter.

**Traced stage by stage:** the tile-size code received 0 ("unset") for
every element. The cascade received a SET opcode with a packed value of
0. **The parser already emitted 0 for `48px`.**

**Root cause:**
- MacSurf's `background-size` parser (fixes191b) compared the unit from
  `css__parse_unit_keyword()` with the public `CSS_UNIT_PX` (0). That
  function returns the *bytecode* unit, `UNIT_PX = 0x100` in this libcss.
- MacSurf wrote it against an older libcss where the two coincided, so
  in our build every length read as `auto`.
- It's the only parser comparing public units this way (checked every
  file that parses units).

**Verified** (`X-bg`): SVG icon 12 → 48 px and centred, SVG logo
48 × 16, PNG 120 → 48 px wide.

### 6. mask-image icons drew as solid blocks (patch 60, libcss)

**The problem:**
- Icons like Minerva's and Vector's are a span with a
  `background-color`, shaped by `mask-image: url(icon.svg)`.
- libcss has no masking, so each drew as a solid block of its colour.
- A real mask property would need new computed-style fields, in files
  MacSurf hand-edited after generation (its `row_gap` is not in
  `select_config.py`, so regenerating would drop it).

**Instead, the parser maps the mask properties to the background ones:**
- `mask-image` and `-webkit-mask-image` → `background-image`, plus
  `background-color: transparent` (unless the value is `none`);
- `mask-size`, `mask-position` and `mask-repeat` (and their `-webkit-`
  forms) → their `background-*` counterparts;
- `mask` and `-webkit-mask` → the `background` shorthand.

The icon then shows its own shape, in the SVG's own colour rather than
the element's.

One lookup, `css__property_id()`, serves both the parser and the
deferred `var()` path, which re-parses by name at cascade time. That
matters because Minerva's `mask-size` is `calc(var(...) + 4px)`.

**Verified** (`CSS-mask-icon.html`, below):
- plain and `var()`-sized masked spans draw the icon at 24 px;
- `mask-image: none` keeps its block;
- `run-vita-sim.sh` counts exactly the two expected solid 24 × 24
  blocks.

**Limits:**
- `-webkit-mask` with `/ size` is dropped: libcss's background shorthand
  doesn't take a size.
- An element with both a background image and a mask shows only the
  mask image.

![mask icons](img/11-real-sites/mask-icons.png)

### Clean checkout, round 2

- Applied 144 + the known 2; L1 PASS; recorded plot streams unchanged.
- Renderer tests 101/101 + 30/30.
- **Simulator:** every check passes, including the new ones: `IMG-svg`
  6 paths drawn, `CSS-mask` exactly 2 blocks, interaction 22/22 at both
  paces, 68 of 68 frames identical batched vs per glyph.
- **Live, Wikipedia excluded (see below):**

  | site | document | extent | RSS |
  |---|---|---|---|
  | example.com | 279 ms | 960 × 544 | 17 MB |
  | Hacker News | 1 580 ms | 960 × 1 303 | 25 MB |
  | CNN Lite | 614 ms | 960 × 3 620 | 25 MB |
  | DDG search | 1 174 ms | 960 × 1 754 | 24 MB |

- **The Vita build** is packaged with libsvgtiny, expat and
  `css__property_id` in the ELF.

### Wikipedia rate-limits repeated test loads

After about 15 loads of the Wikipedia article in an hour (about 50
requests each), Wikimedia answered "Too many requests. Please respect our
robot policy".
- Run `run-live-sites.sh`'s Wikipedia pages sparingly.
- The round-2 chain ran it without them.
- A person browsing is far below that rate.

## Round 3: widths, the mask colour, a device crash (patches 62–66)

### 7. Wikipedia's 1011-px width had two causes (patches 64, 65)

**The finder:** a local snapshot of the article (HTML and its two
stylesheets, served from the scratchpad) plus a temporary box-tree walk,
since removed. It printed every box whose right edge passed 962.

**JavaScript geometry can't help here:**
- `getBoundingClientRect` returns 0s, and `offsetWidth` is undefined.
- That's by MacSurf's design: `MACSURF_JS_GEOMETRY` is 0, because real
  geometry costs about 1.6 s of synchronous layout per measurement
  burst. It's allowed only inside user-event handlers.

**The causes:**
1. **An unbreakable citation URL** (964 px, in an 897-px column).
   - `.content { word-wrap: break-word }` should break it, and MacSurf's
     fixes202 implements the character break. But it fires only when the
     font split returns 0.
   - The Vita's split follows the framebuffer contract and returns the
     whole length when there is no break opportunity.
   - The fallback now fires in both cases.
2. **Minerva's icon-only header button:**
   - `min-width: 44px`, in a flex nav whose last child has
     `margin-right: -12px`.
   - `layout_minmax_block` raised a box's min width to its `min-width`
     but left the preferred (max) width below it. Only the
     intrinsic-keyword branch fixed that up.
   - So the button reported 16 px, the nav got 4 px, and the button sat
     25 px past the screen.

**Checked:** in the final layout pass, no box passes 960. The regression
page `CSS-overflow-x.html` holds both cases, and the simulator asserts
the page is exactly 960 wide.

### 8. The mask's transparent colour must win (patch 66)

- Live, the page-action icons were still solid bars after patch 60.
- Minerva's `.minerva-icon { background-color }` comes **after** its
  `.minerva-icon--* { mask-image }` rules, at the same specificity, so it
  beat the injected `transparent`.
- A masked element's colour only shows through the mask, which isn't
  drawn, so the `transparent` is now important, on that opcode alone.
- **Verified:**
  - `CSS-mask-icon.html` gained the Minerva-order case (MASKED-LATE),
    and it draws the icon;
  - live Wikipedia shows the language, star and pencil icons.

### 9. A layout assertion aborted the browser on the device (patch 62)

Hardware run 14 (doc 10): on claude.ai's Cloudflare challenge page, the
line min-width assert fired: `assert(0 <= *line_min)`, layout.c:1121,
from the crash dumps. The likely path:
- under `white-space: nowrap`, a line's min is its max;
- max sums inline boxes' `max_width`;
- NetSurf's `UNKNOWN_MAX_WIDTH` / `UNKNOWN_WIDTH` sentinels are
  `INT_MAX`, so one left in the sum wraps negative.

The line, block and table min/max functions now clamp to `0 ≤ min ≤ max`
before their asserts. The line clamp logs `minmax line clamped`, so a
device run shows whether and where it fires.

## Round 4: claude.ai — past Cloudflare, into the React app (patches 69–75)

Hardware run 15 (doc 10): Cloudflare turned claude.ai/code away as "too
old", YouTube drew black and white, and the system screenshot saved
nothing (fixed on the device side by patch 68, SELECT + ✕). This round
takes claude.ai from the challenge page to its own React app.

### 10. Cloudflare scored the request, not the browser (patches 69, 70)

The challenge page ran and then showed "Browser not supported". But real
Chromium (Playwright) is not challenged at all. It gets the sign-in page
directly, so the decision is made on the request. Measured with curl
over HTTP/1.1 (the Vita's libcurl has no HTTP/2):

| request | answer |
|---|---|
| Chrome Android UA | 403, "Just a moment..." |
| Chrome UA + `Accept: text/html,...` | **200, the app** |
| Chrome UA + that Accept, over HTTP/2 (curl's) | 403 |
| the Vita UA (patch 55) + that Accept | 403 |

- **Patch 69:** `ux0:data/VitaBrowser/useragent.txt` picks the user
  agent. It is created on first start with `chrome` (Chrome 140 on
  Android); `safari`, `firefox`, `vita` or a whole string also work.
  `navigator.platform` and `navigator.vendor` follow the choice.
- **Patch 70:** page loads (verifiable fetches) send Chrome's navigation
  `Accept` and `Upgrade-Insecure-Requests`. Before, it was curl's `*/*`.
  Scripts' fetch()/XHR and sub-resources are unchanged.

The simulator uses the Vita's own curl + mbedTLS, so its TLS fingerprint
is the device's. It now gets the app page, not the challenge.

### 11. The app is ES modules: 66 of them, 19 MB (patch 71)

claude.ai's page has one `<script type="module">`:
- its static imports reach **66 modules, 19 MB** (three levels);
- dynamic `import()` reaches **2,645 modules, 167 MB**.

MacSurf ran external modules as classic scripts, which is a SyntaxError
at the first `import`. Its loader could only find inline modules and the
Mac's disk cache.

QuickJS links a module graph synchronously, so the sources must be in
hand before linking starts. The loader now works like this:
- `js_exec_module` scans the module's static imports (`from "x"`,
  `import "x"`, resolved with `nsurl_join`).
- It fetches each level in parallel through `fetch_get_blocking()`: a
  private curl multi with 6 transfers, the same UA, CA bundle, name
  lookups and timeouts. `file:` URLs are read directly.
- Level by level, that is **65 modules in ~1 s** on a desktop link.
- The loader compiles each module from that registry and frees its
  source.
- A dynamic `import()` fetches its module, and that module's static
  graph, when it runs. It blocks, as a module link must.
- Module scripts are deferred, and inline ones are too (queued, then run
  after the deferred scripts).

Two more fixes came out of it:
- **The JS heap cap.** At MacSurf's 96 MB every allocation failed, and
  QuickJS reported it as a bare `null` rejection. The compiled app is
  **~99 MB on the 64-bit host**; about 60 MB is expected on the Vita. The
  cap now scales with the pointer size: **128 MB of the Vita's 192 MB
  heap**, and 256 MB in the simulator.
- **Rejections are visible.** A module's evaluation promise is checked,
  so a throw is logged with its stack instead of passing as success.

### 12. The page's scripts saw an abandoned document (patch 72)

The app threw "Root element #root not found". Its DOM ended at the
`<meta charset="UTF-8">`, **byte 1185**, which is past hubbub's
1024-byte prescan. When the parser meets that meta, it restarts the parse
into a *new* document (`html_process_encoding_change`). The JS realm,
wired to the first document when the thread was made, kept answering
from the abandoned one.

The new `js_thread_rebind_document()` re-wires the realm after the
switch. testpages `JS-module` puts its charset past byte 1024 on purpose.

### 13. Web APIs the app needs (patches 73, 75)

`vita_polyfill.js` is compiled in and evaluated in every realm after the
bridge. Each item below was found as the app's next failure, or by
testpages `JS-apis`, a census of 176 APIs: 121 present before, **151
after**, 10/10 behaviour checks.

- **URL / URLSearchParams:** MacSurf's were stubs. `.entries()` was
  missing, and the app's first failure was spreading it. Checked against
  Node on 20 URLs.
- **TextEncoder:** encoded Latin-1 bytes, not UTF-8.
- **Intl:** QuickJS-ng has none. Added an en-US one, matched against
  Node's ICU on about 200 cases. (Chrome's time format uses a plain space
  before AM/PM, not ICU's U+202F.)
- **IndexedDB:** the app's idb-keyval opens one at boot. It is in memory
  now, and not kept between restarts.
- **getComputedStyle** returned `undefined` for anything the cascade did
  not answer. The UI kit calls `animationName.split` and
  `backgroundColor.trim()` on it.
- **Smaller gaps:**
  - `window.parent` and `window.top` were undefined, so
    `parent.postMessage` threw;
  - `requestIdleCallback` passed no deadline;
  - `document.fonts` was missing;
  - `PerformanceObserver.supportedEntryTypes` was missing;
  - console extras;
  - iterable Headers.
- **Patch 75:** MacSurf skipped any classic script over **256 KB**.
  YouTube's app is one 1.6 MB bundle, so its page stayed an empty black
  shell. The cap is now 8 MB on the Vita.

### Where claude.ai stands (simulator, 2026-09-24)

- `https://claude.ai/code` loads the app.
- The app boots React, routes itself client-side to
  `/login?...returnTo=/code`, and draws the login page's content.
- The page is **unstyled**. claude.ai's CSS does not reach the page yet.
- Host RSS is 260 MB for the 64-bit process; the JS heap is 99 MB of it.
- The remaining console noise is non-fatal:
  - `detectIncognito cannot determine the browser` (a fingerprint
    script);
  - a `Method Not Allowed` from an API call.

### YouTube

- With patch 75, m.youtube.com runs its app and draws its loading
  skeleton.
- The skeleton's black blocks are the "black and white" page of run 15.
  Its colours are CSS custom properties, which are not resolved yet.
- The feed then stops on a `startsWith` of undefined in the bundle. The
  stack is truncated in the log: the bundle's URL is 600+ characters.

## Not done: the gaps left

- **claude.ai/code:**
  - Its CSS: the login page draws unstyled. It is the next item on the
    way to the north star.
  - Then the Vita itself: 19 MB over Wi-Fi, a compile of about 60 MB of
    heap on a 444 MHz CPU, and React's first render. Run 16 measures it.
  - Signing in comes after that.
- **YouTube:** the `startsWith` failure, and CSS custom properties for
  its colours.
- **Wikipedia is 1011 px wide again** under the Chrome UA. The mobile
  skin now comes from `en.wikipedia.org`, with a different header.
- **Minerva's page-action labels** ("Language", "Watch", "Edit") still
  draw, clipped.
  - They reproduce statically: the page-actions markup plus Minerva's
    stylesheet, no scripts.
  - Yet a minimal page with the same hiding rule, flex nesting and
    buttons hides them.
  - A bisection over Minerva's stylesheet is the next step:
    `VITA_SIM_DUMP=1` makes the simulator record the plot dump, where
    the labels show as `PLOT TEXT … STR Watch`.
- **Memory:** host RSS peaks at about 78 MB for the Wikipedia article (a
  64-bit process). The Vita's heap budget is 192 MB. The autotest logs
  `mem[...]` per page on the device.
- **Percentage and em/rem `background-size`** still read as `auto`
  (MacSurf's parser takes px only).
- **`-webkit-mask` with `/ size`** is dropped (libcss's background
  shorthand has no size).
