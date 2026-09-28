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
