# Scorecard log

Each entry: what changed, the scorecard before and after (same Chrome
reference, `--reuse-ref`), and the gaps it was chosen from. Method and
targets: `roadmap.md`. Tool: `tools/scorecard/scorecard.py`.

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

