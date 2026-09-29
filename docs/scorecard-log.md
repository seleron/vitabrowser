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
