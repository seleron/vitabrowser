# Roadmap: from fixes to a product

*Written 2026-09-28 night. Owner request: "we are making individual fixes for
things we identify along the way; we need this browser to operate like a
real browser with a systemic plan in line with the larger project plan."*

This document turns the brief's phases (README §9) and the north star
(`north-star.md`, R1–R8, stages S1–S7) into workstreams that are **chosen by
measurement**, not by whichever page broke last. Where it and the brief
disagree, this is newer.

## 1. Where we are

- Patches 1–144. Stages S1–S5 pass in the simulator; S5 (SSE streaming) and
  the JS platform pieces behind it are done (doc 13). Hardware runs 1–22
  confirm the engine, fonts, network, JS, popups and input on a PCH-2000.
- Every recent patch was found by one page going wrong (claude.ai, Google
  sign-in, YouTube). That found real bugs, but it measures nothing: nobody
  can say whether the browser is better at *news sites* this week, or what
  share of the Phase 1 bar is met.

## 2. The measurement system

Three layers, each with a job:

| Layer | What | Job | Where |
|---|---|---|---|
| A. Conformance gates | the simulator suite (test pages, JS gates, interaction pass, Vita-pace, pixel checks) | stop regressions; every fix adds a gate | `tools/run-vita-sim.sh` |
| B. **Scorecard** | ~20 real sites in 8 tiers, each loaded in the simulator and in headless Chrome at 960x544 with the Vita's UA | measure progress toward the Phase 1 bar and choose work | `tools/scorecard/` |
| C. Device runs | one bulk run per batch (autotest + short manual list) | truth on hardware: speed, memory, input | doc 10 |

**Scorecard metrics per site** (`tools/scorecard/scorecard.py`): state
(loaded / timeout / crash), seconds to Done, distinct JS exceptions (Chrome's
page errors beside them), **text** = recall of the 400 most frequent words
Chrome shows, **visual** = first-screen similarity (where the ink is, and
tone), and **score** = 100 × (0.15 loaded + 0.45 text + 0.40 visual). Live
sites change, so a run can reuse a fixed Chrome reference (`--reuse-ref`)
while the browser changes.

## 3. Definition of done

**Phase 1 exit ("daily driver", brief §9):**

- scorecard: every tier except `spa` averages **≥ 85**, no site crashes,
  no site times out;
- downloads land in `ux0:/download/` and appear in the Vita's file manager;
- chrome: URL entry, back/forward, bookmarks, **history**, **find in page**,
  error pages that say what failed, a settings page (UA, zoom, blocking);
- a device run confirms the scorecard's top 10 sites on hardware.

**North star (S6/S7):** an authenticated claude.ai session on the Vita.
Google sign-in is refused by Google's policy (run 22/23: "this browser or
app may not be secure", the same answer headless Chrome gets), so S6 goes
through claude.ai's **email** login, whose blocker is its invisible hCaptcha
(needs real script-made cross-origin frames, WS-B2).

## 4. Workstreams

Each stream lists its acceptance test. Work inside a stream is ordered by
scorecard impact: group failures by root cause, fix the cause with the most
sites behind it, add a gate, re-score.

### WS-A Rendering correctness (Phase 1 items 6–7, Phase 2 item 12)
Found by the scorecard's visual metric and by reading its worst frames.
Known now: `opacity` on inline boxes (example.com shows every language at
once), `light-dark()` / `color-scheme`, SVG `<use>`. The brief's CSS queue
in MacSurf's order: transform (Q1), two-value `gap` (Q2), `caption-side`
(Q3), `table-layout: fixed` (Q4), multi-column (Q5).
*Acceptance:* a test page per feature in the suite; tier scores rise.
*Status (2026-10-06):* Q3 done in the sim (patch 201): `<caption>` /
`display: table-caption` is a block as wide as the table, above or below
its border box by `caption-side`, with room made in the flow; it used to
be an inline in an implied first cell. CSS-table-caption.html (CAPTION201)
8/8, 3/8 without the patch. Q4 was already in the stack (fixes184/573).
*Status (2026-10-07, cloud session, live sites unreachable so the
scorecard could not run):* gaps were found instead with geometry and
cascade probes against local Chromium (testpages/pages/PROBE-*.html) and
fixed with a Chromium-verified, disarm-checked gate each: [hidden] /
dialog / template / closed-details hiding + summary toggle (203),
display: flow-root (204), grid repeat(auto-fill|auto-fit) by container
width and spaced grid-area placement (206), svh/lvh/dvh units and lh
(207), -webkit-line-clamp (208), ch = 0.5em (210), CSS nesting (211),
discrete media features such as prefers-reduced-motion and hover/pointer
(213), line-height: normal = 1.164 with no forced 1.33 (214), the
@supports of absent properties (216), inline <svg> auto sizing (217),
<progress>/<meter> bars (218), unloaded iframe / video placeholders (219),
letter-/word-spacing and justified text on the Vita text path (220), the
space between inline-blocks, images and buttons (221), fieldset/legend
(222), range and color inputs as widgets (223). Open from the probes:
@container (dropped), @layer (flattened), Shadow DOM, date inputs as
plain text fields. Checkbox/radio at browsers' 13 x 13 (224); no margin
on text inputs, buttons, selects, textareas (225).

### WS-B Web platform (R1, R2, R4)
1. **Event model conformance.** A listener registered on `document` without
   `capture` ran during the capture phase, before the target's own
   listeners (seen replaying claude.ai's email form). Dispatch must follow
   capture → target → bubble, with `eventPhase`, `stopPropagation`,
   `defaultPrevented` shared by every listener of one event.
2. **Frames.** The engine loads only parsed iframes. Patch 143 emulates
   script-made *same-origin* frames; cross-origin script-made frames
   (hCaptcha, embeds, OAuth widgets) need real loading into their own realm
   with the postMessage bridge (doc 12).
3. **API census** (JS-apis 161/176): close the missing 15 where sites use
   them; `innerText`. *2026-10-07:* 172/176 -- crypto.subtle digest + HMAC
   (patch 215); still missing attachShadow, caches, serviceWorker,
   mediaDevices. Inline elements' getBoundingClientRect (202) and
   computed colour alpha (212) fixed. The engine's NaN / Infinity
   constants were 0 (a C89 port's flattened union; quickjs patch 05).
4. **Canvas 2D** (*2026-10-11, patch 251*): a real raster behind
   getContext('2d') -- paths, strokes, gradients, images, text, clipping,
   pixel read-back, toDataURL; it was a no-op stub. First of the two
   prerequisites for an hCaptcha attempt (docs/wasm-hcaptcha-measurement.md);
   WebAssembly with time slicing is the second.
5. **WebAssembly** (*2026-10-12, patch 254*): wasm3 behind the
   WebAssembly API; long calls draw the page every 200 ms and can be
   stopped; wasm time is outside the script budget. *Run live in the
   simulator 2026-10-12 (patches 255-256, doc 10 "Since run 33"):* hsw
   runs (~0.6 s per frame on the host, ~20 s on the Vita estimated) and
   its answer reaches the server, which refuses it (`success: false`) --
   not plumbing. claude.ai's email sign-in stays blocked there.
   *2026-10-13:* not the fingerprint either -- Chromium without the
   interfaces this engine lacks, with its values or network stack, still
   passes, and the engine is refused under any user agent; hsw computes
   something different here (docs/wasm-hcaptcha-measurement.md, "Why
   hCaptcha refuses us"). Traced call by call in both engines (patch
   268): same requests, same swallowed exceptions; the standards gaps
   it found are fixed (269-272) and the demo still refuses (gate
   green; scorecard r52: no site moves but live content). *Replayed*
   (tools/hcaptcha/hsw-replay.js): the engine's wasm3 computes Chromium's
   hsw run identically, and with the engine's whole request but `n`
   transplanted Chromium still passes -- the refusal is in hsw's
   fingerprint `n`; ten more surface differences given to Chromium all
   pass. Next, if pursued: key order and the native-function shape
   (docs/wasm-hcaptcha-measurement.md, "Record, replay").
*Acceptance:* JS gates per item; claude.ai email login reaches "check your
email".

### WS-C Performance (brief Phase 2 item 13)
1. **The module graph blocks the main loop** (run 22: 54 s frozen while 91
   dynamic modules were fetched and compiled). Fetch asynchronously; compile
   in slices between frames.
2. Lazy sub-resources (images below the fold), incremental reflow.
*Acceptance:* claude.ai reaches /login in < 60 s on hardware with input
responsive throughout; scorecard `Done s` per tier.
*Status (2026-09-29):* item 1 done for dynamic `import()` (patch 159 +
patches/quickjs/03): the graph is fetched with non-blocking transfers and
compiled in 12 ms slices between frames (sim: claude.ai's longest slice
151 ms; JS-module-async.html proves timers run while a graph loads).
Static `<script type=module>` graphs (external and inline) load the same
way since patch 160: prefetched as soon as the script's text is known, the
conversion (deferred scripts, then DOMContentLoaded) waits for them, so
order is unchanged (JS-module-static-async.html: longest timer gap 17 ms,
2035 ms without the prefetch). Item 1 is done in the sim; device numbers
come with run 26. Duplicate-fetch measurement is closed (patch 161,
JS-module-dedupe.html 5/5 + full gate): with the parallel pipelines, each
module URL is now fetched and evaluated exactly once -- a module in a
static graph AND import()ed, the same import() twice, the same src twice,
and a module script AND an import() of it all share one registry card; the
page fetch registers first and the import()s wait for it. Server-side
proof via httpd /fetch-count (9/9 files fetched once, all in flight at
once). Item 2, lazy sub-resources, is closed in the sim (patch 162):
images past the first 10 of a page load when scrolled near (the
fixes738 queue is now drained after every frame, and the parser's
speculative `<img>` fetch, which had fetched every image at load and made
the queue moot, keeps to the same 10); JS-lazyimg.html 4/4 via httpd
/fetch-count (3/4 without the fetch budget, 1/4 without the drain).
Device verification in run 26. Incremental reflow for late objects is
closed in the sim too (patch 163): an image that arrives after layout
re-lays out only its own lines and moves what follows, instead of a full
layout_document per batch (JS-reflow-stall.html: 6-14 us per relayout,
longest main-loop gap 38-40 ms instead of 98-109 ms on 5000 paragraphs;
positions identical to a full layout's). Still full: a display: block
image with no size (margins collapse through its empty block), floats or
positioned boxes in the way, and every script DOM change (a whole-tree
rebuild) -- that last one is the next WS-C item. Then re-score `Done s`
per tier.
Script-driven DOM changes, first part (patch 165): measured on 5000
paragraphs, every text change cost a full box-tree rebuild plus a full
layout -- 257-1496 ms of stall on the host. A change inside a block of
inline content (textContent, innerHTML with inline markup, a text node's
data, an inline child added or removed) now rebuilds only that block's
boxes and lays out only its lines: ~23 ms of stall (2.7 ms of work),
positions identical to the full path (JS-dom-stall.html). Block
insertion/removal (patch 166): a paragraph a script inserts, appends or
removes among other blocks is now built alone and placed with the
layout's own margin collapsing (5-7 ms of work, stall 24 ms instead of
250-273 ms; all 5001 blocks identical to the full path, and a stress page
of first/last-place edits, batched appends and removals). Still the full
rebuild: lists (markers), nested blocks, floats/tables/flex around the
change, objects and form controls. WS-C's script-change items are done in
the sim. Re-scored `Done s` per tier 2026-09-30 (patches up to 183,
scorecard r18-full-183): all 21 sites, all-tier mean 65.3 -> 73.6,
search 42.3 -> 81.3, no cross-site regression; the two slowest
loaded pages (make.wordpress.org/core 5.9 s, the guardian 4.6 s)
are script-DOM-change heavy -- the incremental-reflow work below.
Class changes (patch 173, 2026-09-30): a class set on an inline-level
element (a span, a link, a label -- the usual UI state toggle) was a full
rebuild (258-282 ms here) and, the third time in a row, suppressed
(fixes1135: the page kept its old look). It now rebuilds only the block
holding it through the patch 165 path: 24-27 ms, geometry identical
(hash of 588 values against the unpatched build). Still the full rebuild:
a class change on an element whose own box is block-level (its box's
style must be recomputed) -- the next WS-C item, with lists and nested
blocks.
Block class changes (patch 174, 2026-09-30): the element's own block box
is taken out and the element built again with a fresh cascade, put back
where it was -- patch 166's removal + insertion: 250-268 ms -> 16-27 ms,
geometry identical (636-value hash against the unpatched build). Declined
to the full rebuild when the page's own CSS has a sibling combinator
(`+`/`~`: the class could restyle following siblings) or the block holds
objects, controls, floats or a list marker. Found on the way (patch 175):
getBoundingClientRect / offsetTop / offsetLeft put a bordered box a
border's width too low and too far right. Still the full rebuild:
lists (markers, numbering), nested blocks (a new div holding paragraphs),
floats/tables/flex around the change, pages with sibling combinators.
Lists and nested blocks (patch 176, 2026-09-30): a list item or a block
of blocks a script adds or removes is built alone and the page laid out
once (markers renumbered, margins collapsed through the nesting exactly):
179-189 ms -> 45-46 ms on a 2500+2500 page, geometry identical (616-value
hash). What remains of WS-C's script-change list: floats/tables/flex
around a change, objects and form controls, class changes on pages whose
CSS has sibling combinators; and a whole-page layout is still ~30 ms per
list/nested change (a local placement for those would need the list
numbering and through-collapsing done locally).
Found on the way (patch 164, a correctness fix, not WS-C): without iconv
(the Vita's libparserutils) the last <=64 characters of a document or
stylesheet were dropped when the data ended in the pass that filled the
4 KB UTF-8 buffer -- a page's last script never ran, a stylesheet lost its
last rule (JS-parse-tail.html).
The parked google main-script error (scorecard next-item since r2) got its
first fix (patches/quickjs/04 + patch 167, the glue): the host's own
bootstrap globals (function declarations and `var` hoists installed by the
VitaBrowser realm build) were `configurable: false`, so a page that wraps
one with `Object.defineProperty` -- google's rAF polyfill does exactly this
-- threw and killed the bundle. The flag is ON around the realm build only
(page scripts see the standard frozen declarations again). Verified: full
gate green, and in the sim google's bundle now gets PAST the defineProperty
wall and reports 3 later JS errors (`at $ra {{0}}:307:407`) where r3 died
before its error reporter even ran; visible text is unchanged (0.184), so a
deeper error is now the blocker -- next step is decoding that frame.
The second wall is decoded (2026-09-30, patches 168-169): `$ra`/`ysa` at
307:407 is google's `_F_installCss` self-check -- every module appends its
CSS in a `<style>` ending in `sentinel{}` and checks the CSSOM saw it --
and our `document.styleSheets` was a stub (cssRules always `[]`,
insertRule a no-op): error "oc" per module, non-fatal. Patch 168 gives a
working CSSOM (parsed cssRules, insertRule/deleteRule, rule.style, one
sheet per `<style>`), a real DOMException (the bridge's was an empty
stub) and a rendered-text innerText (it was textContent: google's
body.innerText was 30 KB of its own CSS, which is also why the scorecard
saw none of its words). Patch 169 makes a stylesheet that changes after
load restyle at all: the selection context was frozen at load, so no
post-load CSS change -- CSSOM, CSS-in-JS, a late `<link>` -- ever applied.
Sim: google reports 0 JS errors (24 beacons before), score 40.8 -> 45.5
(text 0.184 -> 0.289). Still missing: the "Trending searches" list -- its
DOM is built but stays hidden (`.WrKXc` needs class `pne3Yd`, which the
component adds only when its `/complete/search?client=mweb-insp` result
has rows; the XHR returns 200 / 6.9 KB, so the parse or the callback is
the next thing to trace) -- and the mobile header (ALL / IMAGES).
Also seen: `#gb-main` gets `style="min-height:undefinedpx"` (a viewport
height the bridge answers `undefined` for).
Google residuals, 2026-09-30 morning: (1) footer links ran together in
innerText -- flex items are blockified; fixed (patch 177), google 62.9.
(2) `min-height:undefinedpx` is BY DESIGN: an inline script writes
`#gb-main.scrollHeight + "px"` during parsing, before any layout, and the
bridge answers geometry `undefined` until the tree settles (fixes1014/
1087: a fabricated 0 written back once erased whole page sections; a NaN
write is a no-op). Matching Chrome needs a forced synchronous layout
during parse -- its own risky round. (3) The ALL/IMAGES header IS in the
page (innerText has it) but drawn off-screen: `<body>` sits at y=-10 and
the header's items are not centred in its 48px flex row (they start at
its top), and the Sign-in button stretches into a tall block at the left.
Google's CSS is plain (`header{display:flex;min-height:48px}`,
`#gb-main{display:flex;flex-direction:column;min-height:100%}`,
`body,html{height:100%}`): a flex layout-engine investigation, next.
Found on the way, also next: the bridge's `element.matches()` answers true
for `:root`, pseudo-elements, `:hover`, `:first-child`, `:nth-child()` on
any element and false for `body > div` / `:is()`; querySelectorAll finds
nothing for `:root`, `:first-child`, `:nth-child()`, `:is()` (Chromium
comparison on example.com, 9 of 14 selectors wrong).
Selector engine DONE (patch 178, 2026-09-30): a Selectors-4 parser and
matcher behind matches/closest/querySelector(All) -- JS-selectors.html
85/85 against Chromium's answers for the same document (14/82 before).
Found by the full scorecard while verifying it (patch 179): rte.ie
crashed 4 s in -- libdom segfaulted dispatching DOMSubtreeModified at the
NULL parent of a detached text node whose data a script set (core-js /
Vue 2's microtask shim); and that shim never ran here anyway, because the
bridge's MutationObserver produced no characterData records (fixed in
178, with the missing appendData/insertData/... ). Full scorecard: all 21
sites load; news sites re-scored on fresh Chrome refs at or above r3.
Google's header (patches 180-181, 2026-09-30): four engine bugs on plain
CSS -- libcss dropped `flex: 1 0 auto` (the 0 parsed as a basis), dropped
calc() line-heights, margins collapsed THROUGH flex/grid containers
(<body> pulled 10px up by the footer's -10px margin), a stretched nested
flex container fell back to its content height, and min-/max-height
ignored box-sizing: border-box. ALL/IMAGES now show in the header, the
apps + Sign-in group sits at the right edge (CSS-flex-header.html 6/6 as
Chromium). Fixed, patch 182 (2026-09-30): the root cause was libdom -- a
script `innerHTML` during parse flipped the LIVE document into
quirks mode (the fragment parser sees no doctype), so class
selectors matched case-insensitively and og.css's
.gb_E {position: absolute} captured the account bar (class
gb_e), pulling it out of the header's flex flow. The fragment
now keeps the context document's mode (CSS-account-bar.html
cases 1-3). google 64.8 → 81.2 (text 0.658 → 1.0, scorecard
r16-google-182). Fixed, patch 183 (same day): the flex line's USED cross size was
max(item cross), so the 64px item GREW the 48px line to 64, the
center free space became 0, and align-items: center degenerated to
flex-start. With a definite container cross size the item no longer
grows the line (CSS Flexbox 9.4.5); centering uses the USED size and
the item overflows −8/+8 as in Chromium (CSS-account-bar.html 5/5,
FLEXHDR 6/6, full gate clean). The whole account-bar task is done.
Fixed, patches 184 + 185 (2026-09-30): scorecard r18-full-183's single
most-dropped CSS declaration was `-webkit-appearance: none` (13 of 20
sites -- every webkit-flavoured page styles its form controls with the
prefixed name); libcss accepted neither the prefixed name (unknown
property, the declaration dropped whole) nor the legacy widget values
(`button`, `textfield`, ... -- 4 more sites). 184 (libcss) reads
`-webkit-appearance` as `appearance` via `css__property_id`'s alias
table and accepts the legacy widget names as `auto` (on webkit they mean
"use the platform widget", which is exactly what `auto` is here -- the
engine paints one built-in widget, so accepting them implies no new
rendering). 185 (netsurf) lets `getComputedStyle(el).appearance` answer
`auto`/`none` (Chromium parity; the property was unreadable from JS).
CSS-appearance.html 6/6 (default auto; `-webkit-appearance: none` ->
none; legacy `button`/`textfield` -> auto; unprefixed `none` unchanged;
unknown value drops to auto).
Then the trending list itself (patches 171-172, same night): a temporary
QuickJS throw trace showed what google's try/catch blocks swallowed -- (1)
Closure's safe-CSS builder reads `.sheet` of a `<style>` in
`createHTMLDocument('')`, our getter said null outside the main document,
and a chain of Wiz services failed; (2) a second polyfill run in the same
realm split the CSSRule classes (`instanceof CSSStyleRule` false); (3) its
HTML sanitizer needs `createRange().createContextualFragment`, a real
TreeWalker, iterable `attributes` with every attribute (ours listed ~23
fixed names) and `XMLSerializer`. All four now work (JS-sanitize.html 7/7,
Chromium-checked), and google.com in the sim shows **Trending searches**:
score 52.3 (r6; 40.8 at r4), text 0.421. Still missing: the ALL/IMAGES
header, the entity subtitle under each trend (on the same line here),
footer links that run together in innerText (flex items are blockified in
browsers), `min-height:undefinedpx`.

### WS-D Memory and robustness (R7, Phase 2 item 11)
Per-page memory report (patch 142 started it), a JS heap budget that
degrades (stop the page's scripts, show an error) instead of silently
failing, page cache caps, crash triage.
*Acceptance:* two heavy pages in a row never leave the browser unusable;
an out-of-memory page shows an error page.

### WS-E The browser itself (Phase 1 items 9–10, Phase 2 item 14)
Downloads to `ux0:/download/`, or `ux0:data/VitaBrowser/downloads/` where
the safe eboot may not write there (patch 170; every VPK is safe), with
Content-Disposition names, progress, downloads page, history page, find in page, error pages, settings page,
desktop/mobile UA toggle.
*Acceptance:* interaction-pass steps for each; device checklist.
*Status (2026-10-10):* find in page done in the sim (patch 230): "/word"
on the URL keyboard, SELECT + DOWN / UP for next / previous, wraps, the
match centred and highlighted, "n of N" on the message line; 8
interaction steps on IN-find.html. History (patch 232): the URL database
is kept across runs; the home page lists the 8 newest visits and links a
history page (200). Error pages were already there (the core's
about:query/fetcherror and about:query/ssl, with Back / Try Again);
a self-signed certificate's reason now reads "The certificate is self
signed." (patch 237: the chain is recorded with curl's mbedTLS backend).
Settings page (patch 241): http://127.0.0.1:<port>/settings, linked
from home -- user agent preset, zoom, content blocking, kept in
settings.txt / useragent.txt, this device only. Still to do: download
progress UI.

### WS-F Auth and bot protection (B2)
Email login (WS-B2 first), cookie persistence across restarts (done),
Cloudflare behaviour on the device's residential IP.

## 5. How work proceeds

1. Run the scorecard (baseline kept in `<WORK>/vitabrowser-work/score/`).
2. Take the lowest tier; read its worst site's frame and log; name the root
   cause; count how many sites share it.
3. Fix the cause with the most sites; add a test page and gate (with a
   disarm check); run the suite.
4. Re-score with the same Chrome reference (`--reuse-ref <run>/ref`, or
   the run's directory); record the delta in `docs/scorecard-log.md`.
   News and search pages drift within hours: a drop there is checked
   against a reference taken with the run before it is called a
   regression (r52).
5. One bulk device run per batch (feedback: device runs are costly).
