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

## Not done: the gaps left

- **Minerva's page-action labels** ("Language", "Watch", "Edit") still
  show clipped, where they should be visually hidden. Minimal pages with
  the same rules (inline, inline-flex, nested flex) hide them, so
  something specific to Minerva's markup or its scripts' changes remains.
  Re-check live now that the icons draw.
- **Wikipedia's article is 1011 px wide:** the page-actions row overflows
  the 960-px screen by 51 px.
- **Memory:** host RSS peaks at about 76 MB for the Wikipedia article (a
  64-bit process). The Vita's heap budget is 192 MB. A device run gives
  the real figure: the autotest logs `mem[...]` per page.
- **Percentage and em/rem `background-size` values** still read as auto
  (MacSurf's parser takes px only).
