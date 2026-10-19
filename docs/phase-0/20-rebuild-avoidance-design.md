# Rebuild avoidance (design, 2026-10-19): shrinking the full reconvert's trigger set

Design only — no implementation in this document's commit. This is
the design pass perf round 3 (2026-10-19, recorded in Doc 10 and in
the session perf file) called for: on a 5000-paragraph page the one
remaining full reconvert is 385–436 ms host, its build is 276–323 ms
of that, and inside the build style selection is 55–57% (~6.5 µs per
element: libcss select ~4.8 µs + parent compose ~2.0 µs). Round 3
measured the per-element levers and rejected them all: box
allocation and property extraction are ~0.12 µs per element (an
arena buys ~1% at real risk), compose sharing is unsound in the
general case (selection resolves `var()` against a per-element
custom-property environment, fixes1268c), and match caching is a
libcss-internals project. What is left is not a faster rebuild but
fewer rebuilds: this document censuses what still triggers a full
reconvert after patches 300/301, and stages the work of answering
those triggers locally or not triggering them at all.

## Constraints (from the record, not negotiable in the design)

1. **Decline rather than guess.** The local-rebuild machinery's
   contract since patch 186: a local answer must be provably the
   answer the full reconvert would have given, or the batch takes
   the full reconvert. Every stage below names its equivalence
   argument before its mechanism. A stage whose argument has a hole
   does not ship as a smaller stage; it does not ship.
2. **The DOM has already committed when a mark is recorded.** Marks
   describe mutations that happened; the box tree is the only
   lagging structure. A full reconvert at any point in a batch is
   therefore always *correct* — local answering is purely an
   optimisation, and abandoning it mid-batch (for a later mark, or
   for the rest of the batch) can never produce a wrong tree. The
   cost guard in stage 1 rests entirely on this invariant.
3. **Declines are non-destructive and counted.** The local paths
   restore or never touch the tree on a decline (patch 301's
   defer-and-retry rests on it), and the per-reason counters
   (fixes1075) plus the LIFE decline lines are the census
   instrument. No stage may add an uncounted full-reconvert path.
4. **Marks hold referenced nodes, never bare pointers**
   (macos9_reconvert_node_ref discipline, registry tokens against
   the fixes550 ABA problem). Raising any bound raises the number
   of references held between mark and fire; stages must state the
   bound they hold and why it is safe on the device's memory.
5. **Host numbers are relative evidence only** (Doc 10's framing,
   ~20–30× host→device). A stage's perf claim is a host
   before/after on a named page plus the mechanism, never a device
   promise. A stage that cannot show a host win does not ship.

## Census — what still triggers a full reconvert (post-301)

From the reconvert code (macos9_reconvert.c) and the record:

- **T1. Initial conversion.** Every navigation builds the box tree
  once (~385–436 ms on a 5000-¶ page). Not eliminable — the tree
  must exist — but it is the floor every other trigger is compared
  against, and the reason a *second* full pass is the expensive
  accident: patches 300/301 removed the bench pages' second pass;
  T2–T6 are the remaining ways to pay it.
- **T2. Batch overflow.** More than RECONVERT_MAX_EXTRA (32)
  distinct precise marks in one slot collapses the slot to coarse
  (logged), and a coarse slot's only answer is a full reconvert.
  The 32 was sized from the bench pages' 18-mark show() bursts
  (patch 301's header); a framework render burst — text and class
  across 50+ rows — overflows it by construction.
- **T3. A mark that names no node.** Recorded for DOM-wide
  mutations; precision is impossible, the slot goes coarse. Rare
  and correct; the census counts it so it stays rare on paper, not
  by assumption.
- **T4. Unanswered mutation kinds.** try_local_one answers
  SETATTR_CLASS (its own path) and TEXTCONTENT, INNERHTML,
  APPENDCHILD, REMOVECHILD, INSERTBEFORE, CHARDATA (via
  html_reconvert_local). Any other kind in a batch declines, and
  one undeferrable decline takes the batch full. Which kinds those
  are in practice is a census question (g_mut_counts already
  counts marks per kind; the flush's cause is what needs naming).
- **T5. Two marks declining in sequence.** Interacting declines
  are the structural cases of patches 192/198; the batch goes full
  at once, by design (301). Correct today; a stage may only shrink
  it by shrinking what declines (T6), never by retrying harder.
- **T6. Local-path declines.** html_reconvert_local and the class
  path themselves decline: the block-change scan (a change whose
  box is not a plain block / list item / block of blocks), sheets
  whose sibling combinators or structural selectors reach the
  changed subtree (patches 186/192/198 shapes), and the <head>
  carve-out's boundary (a <style> change, patch 300, correctly
  full: a sheet can restyle anything).
- **T7. Stylesheet mutations as a class.** <style> text writes,
  sheet insert/remove, CSSOM rule edits (patch 190's surface):
  all full today, correctly in the general case — a changed rule
  can match anywhere. Scoping them needs the sheet-reach analysis
  patch 186 already maintains for class changes.
- **T8. Pending-slot overflow.** More than RECONVERT_MAX_PENDING
  (8) distinct mutating frames degrades to reconverting the front
  content. Frame-heavy pages only; counted, currently unmeasured
  on real pages.

The sync-flush declines (notdone / active / paint / inprog /
budget / busy, fixes1075) are NOT triggers: they defer the batch
to the debounced pump, which answers it by the same rules. They
decide *when*, T1–T8 decide *how much*.

## Shape

Extend the local path trigger by trigger, in measured order, each
stage one patch with its own gate — the same shape as patches
186–198 and 300–301. No stage changes what a local answer *means*;
stages only change which batches are eligible to be answered
locally, under a stated equivalence argument, with the full
reconvert always available as the fallback the moment the
argument stops applying.

## Staged surface

- **Stage 0 — name the cause (instrumentation only).** The flush
  already knows why a batch went full; record it as a per-cause
  counter (T2 overflow / T3 no-node / T4 kind / T5 two-decline /
  T6 local-decline / T7 sheet) printed in the navigation summary
  beside the fixes1075 sync counters. No behaviour change. This
  makes T4 and T8 measurable instead of anecdotal and sizes
  stage 1's bound from data, not from the bench pages' shape.
- **Stage 1 — overflow under a cost guard (T2).** Raise the
  precise-mark ring from 32 to a census-sized bound (expected
  128–256), and answer marks in order *while the cumulative local
  cost stays below the cost of the full reconvert being avoided*:
  the budget is the last full reconvert's measured µs for the same
  content (the initial conversion provides the first sample;
  RECONVPHASE already measures every full reconvert). If the
  guard trips mid-batch, the remaining marks take the full
  reconvert — correct by constraint 2, and the batch is logged as
  guard-tripped so the census sees it. Equivalence argument: per-
  mark semantics are exactly patch 301's (same order, same
  defer-and-retry, same two-decline rule); the ring size is a
  buffer bound, not a soundness bound, and the guard can only
  move batches *toward* the full reconvert, never away from a
  safeguard. Lifetime: at most (bound) extra node references per
  slot × 8 slots, held by the existing ref discipline and
  released by the existing slot_drop path — stated here so the
  patch's header must confirm the arithmetic for the bound it
  picks. Expected win: bursts of 33–bound precise marks (the
  framework results-render shape) stop paying 385–436 ms-class
  full reconverts and pay the sum of their local answers instead
  (bench-page marks measured 5–24 ms each, round 3 era).
- **Stage 2 — unanswered kinds, by census order (T4).** Each kind
  the stage-0 census shows mattering gets its own patch and its
  own equivalence argument (the expected first candidate is the
  non-class attribute change whose effect is confined to the
  element's own box). Kinds whose effect is not provably confined
  stay unanswered, on the record, by name.
- **Stage 3 — stylesheet scoping (T7).** A sheet change whose
  selectors' reach — computed by the analysis patch 186 already
  caches for class changes — is confined to a subtree is answered
  by rebuilding that subtree; anything wider takes the full
  reconvert, as today. The reach computation must be proven
  conservative (an under-approximation is a wrong-restyled page,
  the failure class constraint 1 exists to prevent), which is why
  this is stage 3 and not stage 1.
- **Out of scope (engine projects, not numbered patches):**
  batched inserted-content processing at the reconvert (perf
  round 2's note: the per-node mutation-event dispatch inside
  fragment parse and the innerHTML move loop is the same
  architectural cost), streaming/incremental initial conversion
  (T1), and libcss match/compose internals (round 3). Recorded
  here so the boundary is explicit; each needs its own design
  pass if it is ever taken up.

## Failure and lifetime semantics (specified, not discovered later)

- Guard trip mid-batch (stage 1): marks already answered stand
  (their local answers are complete and correct); the rest of the
  batch takes one full reconvert. No partial local state leaks:
  local answers either complete or decline non-destructively
  (constraint 3), so the full reconvert sees a consistent tree.
- Ring overflow past the stage-1 bound: the slot goes coarse,
  exactly the pre-301 behaviour, logged (existing line).
- Content dies between mark and fire: unchanged — registry
  tokens and referenced nodes (constraint 4); a larger ring holds
  more references but introduces no new lifetime *kind*.
- A stage that makes the census worse (more full reconverts on
  the gate suite, for any cause) has failed its gate even if its
  target page improves: the census is the regression check, the
  target page is the win check. Both must pass.

## Gate page (spec)

Stage 1 adds `testpages/pages/JS-batch-burst.html`, prefix
BATCHBURST:

1. Build the 5000-¶ tree (the bench pages' shape), then a show()
   burst of 120 precise marks — 60 rows × (textContent +
   className) — past the old 32-mark ceiling, inside the stage-1
   bound.
2. Correctness: every row's new text and class is read back and
   matches; the summary line lands; BATCHBURST prints its count
   from the page's own reads.
3. Mechanism: the sim log's stage-0 census line for the page
   shows the burst's flush answered locally (zero full
   reconverts after the initial conversion) — asserted by the
   gate script beside the page's print, the way patch 306's
   expectation lives in run-vita-sim.sh.
4. Guard leg: a second burst of expensive marks (class changes
   on large subtrees) whose local answers would exceed the
   avoided full reconvert's cost must show the guard tripping
   and exactly one full reconvert following — proving the guard
   bounds the worst case instead of merely raising the ceiling.
5. DOMSTALL / BLOCKCLASS / interaction / Vita-pace counts hold,
   and the stage-0 census over the whole gate suite shows no
   cause gaining full reconverts.

Stages 2–3 specify their gate pages when they are designed in
their patch headers, as patches 192/198 did.

## Cost expectation

Stage 1's cost is one larger static ring and a µs comparison per
mark — noise against the costs involved. Its expected saving is
per-burst: a full reconvert (385–436 ms host on a 5000-¶ page,
round 3) replaced by the sum of local answers, bounded above by
the guard at the avoided reconvert's own cost, so the stage
cannot make a burst slower than today by more than one mark's
local answer. On the device factor that bound is the difference
between a results render freezing the page for seconds and
responding inside the burst. Stages 2–3 are sized by the census
when their turns come; this document deliberately promises
nothing for them beyond their order.
