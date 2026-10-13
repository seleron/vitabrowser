# Scorecard log

Each entry: what changed, the scorecard before and after (same Chrome
reference, `--reuse-ref`), and the gaps it was chosen from. Method and
targets: `roadmap.md`. Tool: `tools/scorecard/scorecard.py`.

## 2026-10-13 — run 37 build, fresh Chrome reference (r51-full-267-fresh)

No engine change: the run 37 hand-off build (patches 168-267, restaged
from c7b26d1, full gate green) scored against a **fresh** Chrome
reference, as r49 asked -- its BBC and Hacker News references were two
days stale. All 21 sites loaded, JS error counts unchanged from r49;
oldreddit (ours and Chrome's both "Welcome to Reddit") and ddglite
(Chrome's side walled) stay out of the tier means as before.

| tier | r49 (r45 ref) | r51 (fresh ref) |
|---|---|---|
| static | 86.6 | 86.6 |
| wiki | 85.1 | 88.2 |
| news | 82.3 | 85.9 |
| forum | 79.9 | 87.7 |
| wordpress | 77.3 | 77.3 |
| jquery | 88.6 | 88.6 |
| docs | 82.3 | 82.3 |
| search | 78.6 | 79.7 |
| spa | 78.2 | 78.2 |
| **all** | **81.8** | **83.7** |

| site | r49 | r51 | note |
|---|---|---|---|
| hackernews | 75.3 | 89.4 | the stale reference: r50's fresh one gave 91.0; text 0.96 now (the front page turned over) |
| bbc | 80.4 | 89.4 | the stale reference (r49 checked 89.6 against a fresh one) |
| wikipedia | 81.6 | 87.9 | no fundraising banner this load (served at random) |
| cnnlite | 85.5 | 88.8 | live headlines |
| stackoverflow | 84.6 | 85.9 | still clears the challenge on the first load |
| guardian | 80.5 | 81.4 | |
| rte, google, ddglite, oldreddit | | +1.1 to +1.4 | live drift |

Seven references came back byte-identical to r45's (github, youtube,
claude, mdn, jquery, wpnews, archwiki): those pages have not changed, and
their scores are r49's to the digit. So the +1.9 mean is all reference
freshness and live content, not this build -- r51 is the baseline for
the next change (`--reuse-ref r51-full-267-fresh`).

## 2026-10-13 — patches 260-267: Cloudflare's challenge passes (r49-full-267)

Chosen from r45 (mean 80.1): the lowest tier was forum (54.9), and its
fixable site, Stack Overflow (18.2), never got past Cloudflare's "Just a
moment..." page. Six engine bugs in the challenge's path (260-265: blank
frame realm, Document.prototype methods, Navigation Timing, script form
submission, libcss !important operands, libdom form owner); two more found
when 262 regressed the Guardian (266: an edited or late stylesheet never
restyled the page; 267: a box-less iframe made during the load never
loaded). Full gate green first. Same Chrome reference as r45
(`--reuse-ref r45-full-259`).

| tier | r45 | r49 |
|---|---|---|
| forum | 54.9 | 79.9 |
| news | 84.9 | 82.3 |
| wiki | 88.2 | 85.1 |
| **all** | **80.1** | **81.8** |

| site | r45 | r49 | note |
|---|---|---|---|
| stackoverflow | 18.2 | 84.6 | the challenge passes in ~5 s; question list, sidebar |
| guardian | 80.8 | 80.5 | r46 (262, before 266): 70.2, unstyled; r47 (266): 73.1, no consent dialog; 267 restores it |
| wikipedia | 87.9 | 81.6 | its fundraising banner, served at random (both builds, 1 run in 2) |
| bbc | 89.5 | 80.4 | live text drift: fresh reference, 259 build 89.4 vs current 89.6 |
| hackernews | 91.5 | 75.3 | live text drift: fresh reference, 266 and 267 builds both 91.0 |
| google | 80.4 | 78.6 | trending topics drift |

The drops are the live sites moving against a two-day-old reference, each
checked by scoring the old and new builds against one fresh reference;
the only real change outside forum is Stack Overflow's. Next re-score
should take a fresh reference.

## 2026-10-12 — patch 259: Request bodies (not re-scored)

Request had no body readers (text / json / formData / arrayBuffer / blob
were not functions) and kept the raw body; now built on Response's body
code with Chromium's constructor rules (URL resolution, method
normalisation, body hand-off and use-once, clone). Gate JS-fetch-body
30/30 (Chromium 30/30). Not re-scored: no scored site reads a Request's
body on load.

## 2026-10-12 — patch 258: Response.formData() reads multipart (not re-scored)

Follow-on to 257: formData() on a multipart/form-data body (it took
url-encoded only), matching Chromium's parser case by case (files as
File, default text/plain, UTF-8 names, malformed bodies reject). Gate
JS-fetch-body 22/22 (Chromium 22/22). Not re-scored: no scored site reads
a multipart response on load.

## 2026-10-12 — patch 257: FormData sends files (not re-scored)

The gap run 34's hand-off noted: FormData file parts went empty (the
multipart encoder could only build text). Now a Blob of the parts, sent
as bytes through 256's path; append/set store Files and strings as
Chromium does; names escaped, CRLF line breaks. Gate JS-fetch-body 17/17
(Chromium 17/17; before, 12/17). Not re-scored: no scored site uploads on
load.

## 2026-10-12 — patches 255-256: hCaptcha run live; a crash and binary bodies (not re-scored)

WS-B: hCaptcha's hsw run on claude.ai/login in the simulator (docs/
wasm-hcaptcha-measurement.md step 3). hsw runs (~590 ms per frame on the
host); fixed on the way: 255, a NULL box-tree crash when a frame forced a
relayout mid-load (3 of 4 loads crashed), and 256, binary XHR / fetch
request bodies (sent as text, cut at NULs) and XHR responseType
arraybuffer / blob / json. The server then refuses hsw's answer
(`success: false`); stopped there. Gate JS-fetch-body 12/12 (was 4 checks;
Chromium 12/12). Not re-scored: neither change is aimed at what the
scorecard measures (first-load rendering); the gate covers 256, and 255
was checked on the live site (0 of 4 loads crashed after it).

## 2026-10-12 — patch 254: WebAssembly (not re-scored)

WS-B / WS-F: the second prerequisite in docs/wasm-hcaptcha-measurement.md.
wasm3 behind the WebAssembly API, long calls sliced (a frame every 200 ms,
CIRCLE stops), wasm time outside the script budget. Gate JS-wasm 15/15
(Chromium 15/15), gate exit 0 strict; tools/test-wasm.sh clean under ASan +
UBSan. Not re-scored: only claude.ai of the 21 sites probes for
WebAssembly, and its use (hCaptcha) is behind sign-in; the device run will
say how long hsw takes.

## 2026-10-12 — patch 253: late images stop stalling the page (not re-scored)

WS-C, the JS-reflow-stall item doc 10 left open: profiled (per-pass
timers, then tools/vita-sim/sprof.c), the stall was two whole-tree walks
per late-image relayout -- the earlier-abspos scan of patch 191 and the
text-selection labelling -- eight relayouts per four-image burst. Both
now exact and local: the page's longest gap 40-94 ms -> 16 ms (one idle
pass), relayout 5-9 ms -> 7 us. Gate exit 0 strict. No scorecard run:
the sites' Done-s measures the initial load, which this does not touch;
the device run (scrolling while images land) is where it shows.

## 2026-10-12 — patches 251-252: canvas draws; the simulator keeps time (not re-scored)

Tasks from doc 10's queue and the WebAssembly note's prerequisites:
(1) canvas 2D drawing, (2) the JS-fetch-stream "freeze" in the
simulator, (3) settle-deterministic flaky tests. No scorecard run: the
work was a platform feature and gate reliability, and none of the 21
sites was chosen for it (the canvas-drawing ones -- charts, captchas --
are not in the set). Details: doc 10, "Since run 30".

- 251: getContext('2d') draws (it was a no-op); a display:none <img>
  loads and holds window load. Gate JS-canvas-2d 22/22 (Chromium 22/22)
  + on-screen pixels; the raster is ASan + UBSan clean under
  tools/test-canvas-raster.sh.
- 252: the frontend's clocks are monotonic. WSL steps the wall clock
  +1.9 s every ~32 s; the autotest took that for 1.9 s of quiet and
  dumped pages mid-script (JS-fetch-stream in gate 250c/d, JS-class-stall
  in gate 251). Reproduced with a clock-stepping LD_PRELOAD shim: 2/6
  bad before, 6/6 good after.
- SIBINS steps 500 ms apart (they were exactly the 700 ms settle).
- Open: JS-reflow-stall check 3 sits at its 60 ms bound on this machine
  with or without 252 (four late images handled in one main-loop pass).

## 2026-10-11 09:31 — patches 249-250: images fire load; mean 79.8 -> 80.0

A/B on the same fresh Chrome references, run back to back: r43 (patches
to 250) against r44 (the 247 build, `sc.SIM` pointed at the copy of the
tested 247 tree). All 21 sites: 79.8 -> 80.0. wikipedia 85.1 -> 87.9
(visual 0.627 -> 0.698: its images now load the way its scripts wait
for), guardian 80.5 -> 81.1, hackernews 92.1 -> 92.7, youtube 76.9 ->
77.3, bbc 89.9 -> 89.7; the other 15 identical. Two regressions found on
the way and fixed before landing: github crashing 1 run in 6 (a cache
handle aborted mid-broadcast) and bbc out of heap 4 runs in 6 (element
load events reaching a self-re-adding window listener).

## 2026-10-11 06:02 — patches 244-246: the Guardian 74.1 -> 80.1

`--only guardian --reuse-ref r19-full-230/ref`, two runs: 80.1 / 80.1
(text 0.97, visual 0.353 -> 0.536). With 244 alone it was 70.1: the
consent frame that 244 loads ran its heap out and blanked the top of the
page. 246 fixes the cause (DOMPurify's captured getElementsByTagName
answered for the wrong document, doubling the frame's markup on each
sanitize) and sizes the late-linked frame, so the consent dialog is drawn
over the dimmed page as in Chromium's reference. Check runs r37 (r19
references) / r38 (fresh): github 81.8, youtube 76.9, claude 75.4, mdn
81.0, wikipedia 87.9 unchanged; hackernews 93.0, bbc 89.7, rte 83.2,
cnnlite 85.4 on fresh references (their r19-reference dips are the front
pages having moved since yesterday).

## 2026-10-11 01:18 — patches 242-243: github.com 64.7 -> 81.8

`--only github --reuse-ref r19-full-230/ref`, five runs: 81.8 / 81.8 /
81.8 / 81.8 / 65.8 (the last dumped its text before React filled the
commit messages), text 1.0, 0 JS errors (was 64.7, text 0.645, after 240
already 0 errors). The commit messages and the latest-commit box are
rendered by React once <react-app> is upgraded (242) and the page reaches
DONE (243). Check run r34/r35: no regression (bbc/wikipedia dips on r19's
stale reference vanish on fresh ones: 76.4 / 87.9; mdn 79.4 fresh, the
same with the Shadow DOM API disabled).

## 2026-10-10 22:55 — patches 231-236: YouTube and make.wordpress.org/core

Run `<WORK>/vitabrowser-work/score/r25-full-236` (all 21 sites, r19's Chrome
references), then `r26-fresh-hn-google` (fresh references for the two
sites whose content moves by the hour).

| site | r19 (230) | r25 (236) | |
|---|---|---|---|
| youtube | 0.0 (crash) | 76.9 | patch 231 |
| wpblog (make.wordpress.org/core) | 49.5 | **81.0** | text 0.30 -> 0.998; 233-236 |
| hackernews | 91.0 | 83.5 / **92.7** fresh | stale reference (front page moved) |
| google | 80.0 | 70.1 / **81.2** fresh | stale reference (trends moved) |
| every other site | | within +-0.7 | |

With the fresh hackernews/google scores the all-site mean (sites with a
usable reference) is **78.3** (r19: 72.4; r18 at patch 183: 73.6).
make.wordpress.org/core's posts are rendered by the o2 app in JS, and it
took four engine bugs to get there, each with a Chromium-verified gate:
the template in <script type="text/template"> read back escaped (233);
jquery.sonar's offsetParent loop never ending because body.offsetParent
was body (234); getComputedStyle answering nothing for a display:none
element, so jQuery's .show() did nothing (235); and libcss ranking the
style attribute with the leftover specificity of the last matched rule,
so "#content { display: none }" beat style="display:block" (236).

## 2026-10-10 22:20 — full 21-site scorecard, patches up to 230 (desktop)

Run `<WORK>/vitabrowser-work/score/r19-full-230` (all 21 sites, fresh Chrome
refs), against r18 (patch 183, also fresh refs; live sites moved in
between, so single-site deltas of a few points are noise). The first full
run since patch 183: the cloud sessions that wrote 184-229 could not reach
live sites.

| tier | r18 (183) | r19 (230) |
|---|---|---|
| static | 82.0 | 86.6 |
| wiki | 87.2 | 88.2 |
| news | 79.5 | 80.4 |
| forum | 54.1* | 54.4* |
| wordpress | 61.1 | 61.5 |
| jquery | 87.0 | 88.6 |
| docs | 81.8 | 82.2 |
| search | 81.3 | 80.0 |
| spa | 59.9 | 46.7 |
| **all** | **73.6** | **72.4** |

*forum = the two anti-bot walls (stackoverflow, old.reddit), as before.

Every tier but spa is level or up (search -1.3 is google moving 81.3 ->
80.0, within live-page noise; example.com 76.7 -> 89.9, rte +3.2,
hackernews +3.3). **spa's drop is one crash: m.youtube.com SIGSEGV 1.8 s
in** (37.0 at r18). Its scripts read history.length while the window's
first page was still parsing, before the page joins the session history,
and the length walk dereferenced the empty history (patch 136's getter;
fixed by patch 231). Re-scored (`r20-youtube-231`; a fresh Chrome reference taken
the same hour, its text identical to r19's -- the run was given r19's
run directory instead of its ref/ directory):
**youtube 76.9** (text 1.0, visual 0.423). With that, spa = 72.3 and
the all-site mean (sites with a usable Chrome reference, as the
tool counts it) = 76.5.

## 2026-09-30 10:35 — Patch 182: innerHTML no longer flips the document to quirks

Run `<WORK>/vitabrowser-work/score/r16-google-182` (google, fresh Chrome ref).
Before = `r14` (patches up to 181).

| site | before | after | text | visual | JS err |
|---|---|---|---|---|---|
| google | 64.8 | **81.2** | 0.658 → **1.0** | 0.505 → 0.530 | 0 → 0 |

Root cause: libdom's fragment (innerHTML) parser starts in the treebuilder's
"initial" insertion mode, sees no doctype, and asked for QUIRKS mode -- via
`set_quirks_mode()` -- on the *live page's* document. One `innerHTML` during
parse (google sets it before its header is parsed) turned the whole page
quirks; quirks matches class selectors case-insensitively, so og.css's
`.gb_E {position: absolute}` captured the account bar (class `gb_e`) and pulled
it out of the header's flex flow. Patch 182 makes `set_quirks_mode()` a no-op
for a fragment (a fragment is parsed in its context document's mode). Gate:
CSS-account-bar ACCTBAR 3/5 (cases 1-3 = the mode fix pass).

## 2026-09-30 10:55 — Patch 183: flex align-items: center, oversized item

Runs `<WORK>/vitabrowser-work/score/r17-183` (google) and `r17b-news-183` (news
tier), fresh Chrome refs. Before = the r16 tree (patch 182 only).

| site | before | after | text | visual | JS err |
|---|---|---|---|---|---|
| google | 81.2 | **81.3** | 1.0 | 0.53 | 0 |
| news tier | 77.9 | 77.2 | 1.0 | ~0.43 | 0-3 |

Root cause: a flex line's USED cross size was max(item cross); an item
taller than its fixed-height container (64px in 48px) grew the line to
64, cross_free_space became 0, and align-items: center degenerated to
flex-start (item pinned to the top, its bottom 16px past the row). CSS
Flexbox 9.4.5: with a definite container cross size the item does not
grow the line; centering uses the USED size, so the item overflows
equally both ways (md at -8, Sign-in 4-44) -- as Chromium does.
Guarded by available_cross != AUTO, so only fixed-height rows change.
Gate: ACCTBAR 3/5 -> **5/5**; FLEXHDR 6/6; full gate clean.

## 2026-09-30 11:20 — full 21-site scorecard, patches up to 183

Run `<WORK>/vitabrowser-work/score/r18-full-183` (all 21 sites, fresh Chrome
refs). Baseline for comparison = the patch-144 run at the top of this
file (all 65.3). Patches 182-183 introduced **no cross-site regression**:
every loaded site is at or above its baseline; the two forum "blocked"
states are external anti-bot (stackoverflow, old.reddit), not ours.

| tier | baseline (144) | now (183) |
|---|---|---|
| static | 81.3 | 82.0 |
| wiki | 83.7 | 87.2 |
| news | 75.7 | 79.5 |
| forum | 57.4 | 54.1* |
| wordpress | 51.5 | 61.1 |
| jquery | 86.9 | 87.0 |
| docs | 76.1 | 81.8 |
| search | 42.3 | **81.3** |
| spa | 36.4 | 59.9 |
| **all** | **65.3** | **73.6** |

*forum's drop is the two blocked sites, not a layout change (hackernews,
the one that loads, is 87.7).

`Done s` per tier (WS-C's outstanding measurement), mean over the loaded
sites: static 0.4, wiki 1.8, news 3.1, forum 0.8 (hackernews only),
wordpress 4.2, jquery 0.5, docs 1.4, search 1.3, spa 2.7. The two slowest
loaded pages are make.wordpress.org/core (5.9 s, 150+ scripts) and the
guardian (4.6 s) -- both script-DOM-change heavy, i.e. exactly the
WS-C incremental-reflow work.

## 2026-09-28 23:30 — baseline (patches up to 144)

Run `<WORK>/vitabrowser-work/score/base` (21 sites, reference from headless
Chromium at 960x544 with the Vita's UA).

| tier | mean |
|---|---|
| static | 81.3 |
| wiki | 83.7 |
| news | 75.7 |
| forum | 57.4 |
| wordpress | 51.5 |
| jquery | 86.9 |
| docs | 76.1 |
| search | 42.3 |
| spa | 36.4 |
| **all** | **65.3** |

Failures grouped by cause (worst first):

| cause | sites | stream | status |
|---|---|---|---|
| layout assert on `display: inline-grid` (crash) | github | WS-A | fixed, patch 147 |
| parser-blocking scripts fetched one at a time | wpblog (150+ scripts, never loaded) | WS-C | fixed, patch 148 |
| bot walls (Cloudflare "Just a moment", Reddit) | stackoverflow, oldreddit | WS-F | open |
| event dispatch: document/window in the wrong phase, defaultPrevented lost, every event bubbles | all script-heavy sites | WS-B1 | fixed, patches 145-146 |
| `opacity` reached background fills only | example.com (six languages at once), menus/tooltips everywhere | WS-A | fixed, patch 149 |
| `light-dark()` dropped | example.com background | WS-A | fixed, patch 149 |
| `new URL(location)` / `String(a)` = "[object Object]"; no `document.baseURI` | wikipedia, archwiki, python, mdn | WS-B3 | fixed, patch 153 |
| missing interface objects (`Document`, `DocumentType`, `Node.prototype.appendChild`...) | bbc, guardian, oldreddit, mdn | WS-B3 | fixed, patch 153 |
| references blocked for Chrome (not our bug) | ddglite | tool | excluded from means |

Tool fixes in this entry: bot-wall detection on both sides (a blocked
reference is left out of the tier means; a wall on our side is "blocked",
not a layout failure), `--rescore`, and the **gap census** (patches
150-151): every distinct CSS declaration libcss drops and every JS error
message, ranked by number of sites (`cssgaps.md`, `jsgaps.md`).

## 2026-09-29 ~03:30 — patches 145-157 (run `score/r2`, reference = base)

| tier | base | r2 |
|---|---|---|
| static | 81.3 | 82.0 |
| wiki | 83.7 | 83.8 |
| news | 75.7 | 71.4 * |
| forum | 57.4 | 49.1 * |
| wordpress | 51.5 | 64.6 |
| jquery | 86.9 | 86.9 |
| docs | 76.1 | 76.2 |
| search | 42.3 | 42.0 |
| spa | 36.4 | 58.7 |
| **all** | **65.3** | **68.5** |

\* **Stale reference, not a regression.** News and forum front pages change
hourly; against a fresh Chrome capture (`score/fresh-news`) Hacker News is
91.8, BBC 71.8, RTÉ 83.2, the Guardian 70.3 -- at or above base. **Rule:
news/forum sites need a fresh reference every run** (static/wiki/docs can
reuse one).

Gains: github 0 (crash) -> 67 (patch 147), wpblog 26 -> 53 (148),
old.reddit no longer segfaults leaving the page (155; it is a bot wall
either way). The census's top JS errors (`Invalid URL`, `prototype of
undefined`, WordPress `JSON.parse(script.text)`) are gone (153, 157).

Census, what is left at the top (cssgaps.md): per-corner
`border-*-radius` (10 sites; libcss has one radius -- needs 4 properties
through cascade and the painter), intrinsic widths (`fit-content` 8,
`max-content` 7: parser only, patch 158), `height: fit-content` (7, not
modelled), `backdrop-filter`, `cursor`, `-webkit-appearance`,
`color-scheme` (no visible effect here; ignore), `clip-path: inset` (6),
`grid-template-rows: 1fr` (5).

## 2026-09-29 ~21:30 — patches 158-166 (run `score/r3`, reference = base; `score/r3-fresh` for news/forum)

| tier | r2 | r3 | Done s r2 -> r3 |
|---|---|---|---|
| static | 82.0 | 82.0 | 0.30 -> 0.35 |
| wiki | 83.8 | 84.5 | 1.65 -> 1.75 |
| news | 71.4 | 75.8 * | 2.80 -> 2.45 |
| forum | 49.1 | 56.5 * | 0.77 -> 0.97 |
| wordpress | 64.6 | 64.7 | 4.35 -> 4.10 |
| jquery | 86.9 | 86.9 | 0.50 -> 0.50 |
| docs | 76.2 | 76.1 | 1.90 -> 1.40 |
| search | 42.0 | 40.9 | 0.95 -> 0.95 |
| spa | 58.7 | 58.6 | 3.00 -> 2.90 |
| **all** | **68.5** | **70.2** | |

\* Stale reference again (BBC +12, Hacker News +14 are the live pages
moving). Against a fresh Chrome capture (`r3-fresh` vs the r2-era
`fresh-news`) news and forum are flat: BBC 71.8 -> 72.0, RTE 83.2 -> 82.3,
Guardian 70.3 -> 71.3, Hacker News 91.8 -> 91.2.

**Load time did not move, and was not expected to.** Patches 159-166
(WS-C) remove stalls *after* a page has loaded -- module graphs loading
between frames, late images placed without a full layout, script text and
block changes rebuilt locally -- while `Done s` measures the initial load
on the host, where none of those costs was large. Per-site `Done s`
differences above (claude 4.9 -> 3.5, mdn 2.9 -> 1.6, github 3.1 -> 4.2) are
live-site variance: the fresh runs of the same news sites repeat the old
times. WS-C's effect is what its gates measure (main-loop gaps) and what
the device run will show (run 27).

Lowest tier: **search** (google 40.9: text recall 0.21; ddglite's
reference is blocked for Chrome). Next by the roadmap's rule: google.com's
main script error (hidden inside `_DumpException`), parked since r2.

---

## r4-google — the parked google main-script error, revisited (2026-09-29, post-166)

Single-site re-score of the search tier (`--only google --reuse-ref r3`) after
committing the configurable-bootstrap-decls patch (quickjs 04 + glue 167).
Full gate green first (run-vita-sim: interaction 31/31, Vita-pace 25/25, all
module/xfail suites pass), engine symbol `JS_SetGlobalDeclsConfigurable`
confirmed in the rebuilt libquickjs.a **and** the sim binary (not a stale
build).

| tier | site | score | Δ | text | visual |
|---|---|---|---|---|---|
| search | google | 40.8 | -0.1 | 0.184 | 0.439 |

Score and visible text are **flat** (40.9→40.8 is live-site noise; text recall
0.184 identical). But the log tells a different story — the patch **did**
move the failure:

- **r3 (pre):** google's main bundle dies *before its JS-error reporter
  boots* — 0 `jsel` beacons. It hard-fails on the `Object.defineProperty`
  wrap over a non-configurable host bootstrap global (the rAF-style polyfill
  trap).
- **r4 (post):** the bundle now **survives that wall and reports 3 JS
  errors** (`atyp=i jsel=2`), all landing at `$ra ({{0}}:307:407)` — a
  minified frame, one tailing through `<eval>` / `apply (native)`. A **second,
  deeper** wall is now the blocker.

Net: the bootstrap-decls fix is a genuine partial win — it removed the first
throw and let the bundle run further — but it did not change visible text
because a later `jsel=2` error kills the search UX before content paints. The
next investigation is decoding `$ra` at bundle column 307:407 (needs the
google main bundle's source map or a de-minified read of that frame). This is
parked WS-F/B2 territory, not a regression: nothing in the gate moved, load
time 1.7→2.1 s is noise.

## r5-google — the second wall (2026-09-30, patches 168-170)

`--only google --reuse-ref r3`, after the full gate went green (exit 0:
CSSOM 8/8, INNERTEXT 8/8, DOMSTALL 7/7, REFLOW 3/3, interaction 31/31).

| tier | site | score | Δ vs r4 | text | visual |
|---|---|---|---|---|---|
| search | google | 45.5 | +4.7 | 0.289 | 0.438 |

- The r4 errors (`$ra {{0}}:307:407`, 24 `error=` beacon lines in
  netsurf.log; `ysa 313:407`, error "zc", on the device in run 27) were
  google's `_F_installCss` CSSOM self-check against our stub
  `document.styleSheets`. With patch 168's CSSOM there are **0** beacons.
- The text gain is mostly a **measurement fix**: the scorecard reads
  `document.body.innerText`, which was `textContent` -- google keeps its
  `<style>` blocks in `<body>`, so our "visible text" was the first 30 KB
  of its CSS and none of the page's words counted. innerText is now the
  rendered text (patch 168). Every site's text is read the same way, and
  hidden/CSS text could only ever *raise* recall, so the next full re-score
  may move other sites' text down a little: that is the measurement getting
  honest, not a regression. Re-baseline all tiers before comparing.
- Still missing vs Chrome: the "Trending searches" list (built in the DOM,
  hidden until the component adds class `pne3Yd`, which it does only when
  its `/complete/search?client=mweb-insp` result has rows -- the XHR returns
  200 / 6.9 KB, so the response parse or callback is next) and the
  ALL / IMAGES header. Footer links read "PrivacyTerms": flex items are
  blockified in browsers, our innerText uses the unblockified display.

## r6-google — trending searches render (2026-09-30, patches 171-172)

`--only google --reuse-ref r3`, full gate green first (exit 0).

| tier | site | score | Δ vs r5 | text | visual |
|---|---|---|---|---|---|
| search | google | 52.3 | +6.8 | 0.421 | 0.459 |

The "Trending searches" list now renders (it was built in the DOM but
stayed hidden: the component's render threw inside Closure's HTML
sanitizer, and its try/catch swallowed it -- patch 171). 0 JS error
beacons. Most words still "missing" against the r3 reference are the
trends themselves -- live topics change daily (r3: "ireland citizenship
rules change", "monty don"; tonight: "wordle hints", "galway gaa") -- plus
footer words that run together ("PrivacyTerms": our innerText does not
yet treat flex items as blocks). A fresh Chrome reference would score the
trend text as matching.

r7-google (patch 173 on top, regression check): 55.9, text 0.50, visual
0.459, 0 JS errors -- no regression (the text change is the live trend
list moving against the r3 reference).

