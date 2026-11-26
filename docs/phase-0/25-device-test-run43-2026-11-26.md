# 25 — Device test run 43 (2026-11-26)

VPK hand-off build for the 435-475 stack: 41 units since the device last
tested (run 42, pre-435), all of them in the local-rebuild line — the goal was
to stop full-page rebuilds on the heavy-interaction sites.

## VPK identity

| artifact | id | SHA256 (first 12 hex) |
|---|---|---|
| stack tip | `ca17596` — "patch 475: the root restyled in place when its position changes between static, relative and sticky" | — |
| VitaBrowser.vpk | VBRW00001 | `bb501cb858b7` |
| VitaBrowser-ext.vpk | VBRW00002 | `b81fe34875f3` |
| nsvita.elf | — | `c5ba6663c48c` |

Built from a clean clone of the committed HEAD (475 is committed and pushed to
origin/master; gate475 green 17:11Z). Reference dumps were regenerated the same
day from the same 475 stack in an isolated gate — the live gate's autotest stage
had deleted the previous `reference/` set, so the old dumps could not have
matched this stack (vita-netlog.py would have shown false diffs).

## What changed since run 42 (last device hand-off, pre-435)

**Headline: full rebuilds per load on the 7 census sites cut 27.0 -> 1.0**
(end of the 450-469 push, measured at 449/451 on the 7-site set). On the wider
21-site census this loop: 46.0 (451) -> 20.3 (469) -> 18.3 (470) -> 17.3 (471)
-> 11.3 (472) -> 12.3 (473) -> 12.0 (474) full rebuilds per load; 475's census
lands with its ASan turn. No local-path decline is left on the 7 census sites.

### 435-449 — the sheet/box local-rebuild foundation
- 437: box_add_child crash fix — a conversion walk whose subtree a script
  removed stops cleanly (was a crash on script-removed subtrees).
- 440: moved-child order — a moved boxed child is rebuilt; block-of-blocks
  shapes build whole where the local path cannot place them.
- 441: the wpblog intermittent layout_line abort — an inline-block reaching
  line layout unmeasured is measured there.
- 442/443: sheet-in-flight behavior — a batch whose only obstacle is a
  stylesheet still loading waits for it; a sheet change while a sheet is in
  flight is answered against the cascade the boxes hold.
- 444-449: the decline -> local-rebuild fixes, incl. 447 — sheet changes
  re-cascading in place (no full rebuild).

### 450-469 — the deep local-rebuild push
:empty sibling flips, in-place sheet removals and root restyles, live-cascade
walks of in-flight changes, the cost guard deciding on marks-left, sheet-scan
caching, 464's >128-mark coalescing, and the inert-attribute / root-child-list
/ no-box-id local answers, ending at 469 — a sibling rule's reach climbs to the
nearest block above the parent the rebuild cannot take.

### 470-474 — this loop
- 470: a restyled block whose parent is a cell, a float or an inline-block
  (18.3 after).
- 471: a counting flex/grid box rebuilt alone when its counters enter at 0 and
  its counting is unchanged (17.3 after).
- 472: an id change on a boxed element re-selected like any other attribute,
  unless a sibling rule names an id (11.3 after).
- 473: simulator-only test hook that runs 441's unmeasured-inline-block guard
  (no behavior change; 12.3 census is the hook's own pages, not a regression).
- 474: a line holding an object's box (a CSS background) builds its block
  again whole (12.0 after).

### 475 — landed during finalization
- 475: the root restyled in place when its position changes between static,
  relative and sticky. Committed 17:11Z after a green full gate (GATE EXIT 0,
  17:11Z: web APIs 173/176 + behaviour 10/10, xrealm/popup/modules 4/4/6/6,
  Vita-pace interaction 52/52). ASan + 21-site census run in flight at
  hand-off.

## Headline checks by eye

The sites that used to flicker a full-page rebuild on expand/collapse/hover
should no longer do so:

- **wpnews** — menu expand/collapse: the page should stay put (no white flash,
  no reflow of the whole page).
- **oldreddit** — thread collapse/expand: same.
- **bbc** — hover/interaction: same.
- CSS-background-heavy pages (474): a page whose lines hold background-object
  boxes should rebuild that block whole but not the page (visible as a local
  settle, not a full flash).
- Root position changes (475): pages whose root flips static/relative/sticky
  (e.g. a sticky header engaging) restyle in place.

## Notable units (one line each)

- 437 — no more crash when a script removes a subtree mid-conversion.
- 441 — wpblog's intermittent layout_line abort is gone.
- 447 — sheet changes re-cascade in place; the biggest single flicker source
  on the census sites.
- 451 — the first in-place answer for a sheet removal / root change that only
  restyles a few elements.
- 459 — root's own style restyled in place.
- 464 — big DOM batches (>128 marks) coalesce under their common ancestor
  instead of spilling to a full rebuild.
- 469 — sibling-rule reach climbs to the nearest block above: the last
  recurring decline shape on the census sites.
- 472 — id changes no longer force a full rebuild unless a sibling rule
  depends on the id.
- 474 — CSS-background lines no longer decline.
- 475 — root position changes restyle in place.

## Run procedure

1. **Start `receive-results.bat` on the PC FIRST** (Vita on the same Wi-Fi).
   It catches every launch into a fresh `results\net-<date>-<time>-<boot>\`.
2. Install `VitaBrowser.vpk` + `VitaBrowser-ext.vpk` (VBRW00001 / VBRW00002).
3. Launch the app. The autotest self-checks run at startup.
4. Manual site list: **bbc, oldreddit, wpnews, wpblog, google, github,
   youtube** — on the first three, exercise expand/collapse/hover and watch
   for the full-page flicker that 435-475 removed.

## Where results land

`~/Desktop/VitaBrowser-hwtest/results` — read the **fresh**
`results\net-*` dir (the Vita's FTP caches stale files). A run is complete
only when the user says so.
