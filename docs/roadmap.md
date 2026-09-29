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
   them; `innerText`.
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
the sim; next: re-score `Done s` per tier.
Found on the way (patch 164, a correctness fix, not WS-C): without iconv
(the Vita's libparserutils) the last <=64 characters of a document or
stylesheet were dropped when the data ended in the pass that filled the
4 KB UTF-8 buffer -- a page's last script never ran, a stylesheet lost its
last rule (JS-parse-tail.html).

### WS-D Memory and robustness (R7, Phase 2 item 11)
Per-page memory report (patch 142 started it), a JS heap budget that
degrades (stop the page's scripts, show an error) instead of silently
failing, page cache caps, crash triage.
*Acceptance:* two heavy pages in a row never leave the browser unusable;
an out-of-memory page shows an error page.

### WS-E The browser itself (Phase 1 items 9–10, Phase 2 item 14)
Downloads to `ux0:/download/` (Content-Disposition names, progress,
downloads page), history page, find in page, error pages, settings page,
desktop/mobile UA toggle.
*Acceptance:* interaction-pass steps for each; device checklist.

### WS-F Auth and bot protection (B2)
Email login (WS-B2 first), cookie persistence across restarts (done),
Cloudflare behaviour on the device's residential IP.

## 5. How work proceeds

1. Run the scorecard (baseline kept in `<WORK>/vitabrowser-work/score/`).
2. Take the lowest tier; read its worst site's frame and log; name the root
   cause; count how many sites share it.
3. Fix the cause with the most sites; add a test page and gate (with a
   disarm check); run the suite.
4. Re-score with the same Chrome reference; record the delta in
   `docs/scorecard-log.md`.
5. One bulk device run per batch (feedback: device runs are costly).
