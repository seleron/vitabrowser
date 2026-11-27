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

## Results (2026-11-27)

Two launches arrived over the network after the receiver was fixed
(`tools/vita-netlog.py`, 357c51d). Datagrams lost: **0 of 9,976** and **0
of 2,574**.

### Launch 1 (`results\net-20261126-232950-b7c9e2d1`): autotest, then manual browsing

**Autotest complete** (`autotest: done` at 1114 s): 4 passes x 18 pages,
then 2 network pages. Every page settled in 2.5-5.4 s. **No assert, abort
or crash** in the 6,152-line `log.txt`.

**Plot dumps vs the 475 reference: 27 SAME, 7 other; all 7 are
environment, none is a rendering fault.**

| dump | difference | cause |
|---|---|---|
| 19 / 20 NET-http(s)-example, page and `-bottom` (4) | no reference | network pages have no simulator reference dump |
| IN-history | 5 lines: `127.0.0.1:45181` vs `127.0.0.1:8080` | the remote page's port; the sim uses another port, since signal-cli holds 8080 there |
| IN-home-recent | 151 lines | the device shows "From a phone or PC on the same Wi-Fi: http://192.168.10.23:8080/" (only with a LAN address); everything below shifts down |
| IN-settings | 1 line: `6` vs `4` | "N blocked so far": ad and tracker hosts blocked this session |

**Manual sites after the autotest** (load to Done):

| page | load |
|---|---|
| bbc.com | **125.7 s** first load; 24.1 s (a video page), 45.0 s, 5.6 s after |
| old.reddit.com | 14.1 s, 3.3 s (login redirect) |
| news.ycombinator.com | 3.8, 3.5, 2.6 s |
| economictimes (an article) | 23.2 s |
| devnull.land, micjm.com | 2.6 s; 3.2 / 1.9 s |
| google.com | 22.5 s, then Google's "sorry" page (its unusual-traffic check, not a browser fault) |
| github.com | loaded |

**This launch's engine log is incomplete.** The network copy of
`netsurf.log` is capped at 4 MiB (diag.c's `ENGINE_NET_CAP`), and the
autotest filled it by 1068 s, before the browsing. The card copy was
overwritten by launch 2. So there is no engine view (local / full
rebuilds) of bbc, reddit or github in this run.

### Launch 2 (`results\net-20261127-002105-8df9f736`): youtube, claude.ai

| page | load | local rebuilds | declined | full rebuilds |
|---|---|---|---|---|
| m.youtube.com (accounts.youtube.com, accounts.google.com sign-in) | 29.7 s, then 4.9 s | 281 + 298 | 1 ("inline content among the blocks lost an element") | 3 (2 cost guard, 1 local) |
| claude.ai/code | **446.3 s** | 35 | 0 | 2 (cost guard) |

- Local rebuilds were mostly 1-100 ms; a few reached 0.3-0.7 s
  (structural, "7 matching siblings").
- **One local rebuild on claude.ai/code took 10.5 s**, 6x the device's
  ~1.7 s full-conversion budget. It was 446's sibling-rule parent built
  again whole, its subtree counting (471: "counting unchanged").
  - The cost guard checks between marks only, so a single huge subtree
    rebuild cannot be stopped. It tripped after it, and the full rebuild
    was paid on top.
  - The simulator census loads claude.ai's home page, not /code, and never
    ran this path there (largest local rebuild 0.19 s). Whether it is
    device-only is unmeasured.
- claude.ai's local rebuilds total 11.5 s of its 446 s; the rest is the
  page's own work (scripts, network) and its 2 full rebuilds.

### Open items from this run

1. **A size or cost check before a whole-subtree rebuild** (446 / 469 /
   471's parent rebuilds): decline into the full rebuild when the subtree
   is most of the page, rather than finding out after the fact.
2. **bbc's 125.7 s and claude.ai/code's 446 s first loads**, profiled in
   the simulator: is it the engine or the page?
3. **Engine-log coverage:** raise the 4 MiB mirror cap, or browse the
   manual sites in a fresh launch, so the real-site part of a device run
   keeps its engine log.
4. **The headline checks by eye** (wpnews, oldreddit, bbc: no full-page
   flicker on expand / collapse / hover): the owner's impression is not
   recorded yet. wpnews, wpblog and youtube's main page were not in these
   two launches' logs.
