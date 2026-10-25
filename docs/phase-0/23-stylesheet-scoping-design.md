# Stylesheet scoping (design, 2026-10-20): answering a sheet change inside its reach

Design only — no implementation in this document's commit. This is
the design pass leg 6's assessment of doc 20 stage 3 called for:
a sheet change arrives as a nodeless `MACOS9_DOMMUT_UNKNOWN` mark
that always takes the full reconvert (patch 266 made that the
correct behaviour: before it, late and edited sheets restyled
nothing at all), nothing identifies which sheet changed, no reach
analysis exists, and the local machinery has no multi-root subtree
rebuild. Leg 6's verdict was that landing stage 3 needs all three
of those as new pieces, in the open, before any patch — the same
shape item 7 needed (doc 19 before patches 304–307). This document
is that pass. It also corrects one premise of doc 20's stage 3 on
the record (constraint 2 below).

## Constraints (from the record, not negotiable in the design)

1. **Doc 20's constraints 1–5 carry over in force.** Decline rather
   than guess; the DOM has already committed when a mark is
   recorded, so a full reconvert is always correct and local
   answering is purely an optimisation; declines are
   non-destructive and counted; marks hold referenced nodes, never
   bare pointers; host numbers are relative evidence only, and a
   stage that cannot show a host win does not ship.
2. **The 186 analysis is not a reach analysis.** Doc 20's stage 3
   said reach would be "computed by the analysis patch 186 already
   caches for class changes". The record since is narrower, and
   this design is written against the narrower truth:
   `html_rl_sib_sheet_for` (content/handlers/html/html.c) caches a
   per-sheet textual scan (`html_rl_scan_sheet` over the sheet's
   source, keyed by hlcache handle in a ring cache) answering
   per-element questions — sibling-left compounds and `:has`
   compounds for a class change on one element — and patch 313's
   `html_rl_sheet_refs_attr` answers "does any used sheet name this
   attribute". Neither computes the set of elements a *changed
   sheet* can affect. The reach analysis below is a new sibling of
   that scan, sharing its conservatism rules and its cache
   substrate, not a reuse of its results.
3. **Identity is discarded at one boundary, and only there.**
   Every sheet change funnels through content/handlers/html/css.c
   and ends as `macos9_js_mark_dom_dirty(content)` —
   `macos9_js_mark_dom_dirty_node(c, NULL, MACOS9_DOMMUT_UNKNOWN)`
   (content/handlers/javascript/quickjs/macos9_reconvert.h: "no
   idea what"). A design may extend the mark at that boundary
   following the established variant precedent — patch 186's
   `_node2` carrying `old_class`, patch 313's
   `macos9_js_mark_dom_dirty_attr` carrying the attribute name:
   payload copied into the pending record, and a mark without the
   payload declines exactly as before. It may not grow a second,
   private invalidation path around the reconvert machinery.
4. **Soundness is a statement about two selection contexts.** By
   the time a reconvert fires, `html_css_refresh_selection_context`
   (css.c) has already remade the whole selection context from the
   current sheets. A local answer re-selects styles from the NEW
   context for the rebuilt roots only; every element outside the
   roots keeps boxes built under the OLD context. The answer is
   sound exactly when no outside element's selected style differs
   between the two contexts — which is a property of the changed
   sheet's selectors in BOTH versions (a rule edit can unmatch as
   well as match). Reach must bound old ∪ new, never just new.

## Where a sheet change is today (census of the path)

- **Identity exists at the CSS layer.** `html_content.stylesheets[]`
  entries (`struct html_stylesheet`) carry `.node` (the refcounted
  `<style>`/`<link>` DOM node), `.sheet` (the hlcache handle),
  `.modified` and `.unused`. `html_css_update_style(c, style)`
  finds or creates the entry by node and sets `.modified`;
  `html_css_process_modified_styles` then processes each modified
  entry individually: `html_css_process_modified_style(c, s)`
  re-parses the sheet from its DOM node, removes the old sheet
  from the live selection context (`css_select_ctx_remove_sheet`)
  and swaps `s->sheet`. CSSOM rule edits (patch 190's surface)
  write back to the owner element's text, so they enter through
  the same `html_css_update_style` funnel; late sheets arrive via
  `html_convert_css_callback` (css.c) and patch 266's deferred
  refresh. One funnel, three sources.
- **Identity is dropped at the mark.** The refresh call sites
  (the convert callback path and the deferred refresh) emit the
  nodeless mark for the whole content. Which entries were
  processed — and their old and new handles — is known inside
  css.c at process time and nowhere afterwards.
- **The local unit is one block; the batch already composes many.**
  `html_reconvert_local` rebuilds only the boxes of the block that
  holds a change, and lays out just its lines (html.c). What a
  sheet answer needs beyond that is (a) a root SET in place of one
  changed node — the flush already composes many marks per batch
  under patch 301's precise-mark ring and patch 309's cost guard,
  ancestor interaction handled by the two-decline rule — and (b)
  a subtree-rebuild entry: the existing unit rebuilds the block
  *holding* a changed node, while a reach root is a subtree whose
  root box itself must be rebuilt inside its parent (box
  construction on the root within the parent block, under patch
  188's backlink-clearing discipline). (b) is the one genuinely
  new mechanism in this design; it is sized like patch 186's
  original entry, not like a new engine.
- **There is no shadow DOM in this stack.** The bridge has no
  `attachShadow` (no occurrence in macsurf_qjs.c), libdom has no
  shadow-root support, and libcss has
  no `@scope`. A shadow-root-scoped sheet — the confined case leg
  6 named — cannot occur here today. See Open questions.

## Shape

Three pieces, in dependency order:

**A. Sheet identity on the mark.** A new mark variant,
`macos9_js_mark_dom_dirty_sheet(c, index, counter)`, emitted from
css.c's existing mark sites. css.c accumulates the set of entries
processed since the last mark; the variant fires only when that
set is a singleton (the CSS-in-JS / hydration shape: one sheet
edited repeatedly — patch 266's Guardian case is one 640 KB
`<style>` element). A multi-sheet settle window emits the nodeless
mark exactly as today, counted as its own census cause. The
payload is the entry's index in `c->stylesheets[]` plus a
per-entry modification counter (a new field on
`struct html_stylesheet`, incremented in
`html_css_process_modified_style`): if the entry is processed
again before the flush, the counter mismatch makes the earlier
mark decline to full — its replacement's own mark follows in the
same window, so nothing is lost, and no answer is ever computed
from a stale sheet pair. The payload is small and copied, per
constraint 3's precedent; the mark's kind for census purposes is
distinct from UNKNOWN (the patch-308 census splits T7 by cause,
below).

**B. Reach bound from selector anchors, old ∪ new.** A new scan
beside `html_rl_scan_sheet`, textual over sheet source, under the
same decline rules (backslash, unparseable constructs, or any
construct the scan does not understand → the whole sheet is
UNBOUNDED). For each selector in the sheet it classifies:

- *Anchored*: every combinator in the selector is the descendant
  combinator, and the leftmost compound carries an `#id`. Any
  element this selector can match is a descendant of the element
  with that id — reach ⊆ that element's subtree, provable from
  the selector text alone.
- *Unbounded*: anything else (child/sibling combinators, an
  unanchored leftmost compound, a bare element or class
  selector). One unbounded selector makes the sheet's reach
  unbounded.

The bound is computed for BOTH versions of the changed sheet. The
outgoing version's scan must be snapshotted in
`html_css_process_modified_style` *before* the old handle is
released: the existing per-sheet cache is keyed by hlcache
handle and the old handle dies at the swap, so stage 2 stores the
outgoing anchor list (ids only — not rule text) on the stylesheet
entry at process time, freed when the mark it fed is consumed or
dropped. The incoming version scans through the existing cache
substrate by its new handle. The root set is the union of anchor
elements over both versions; if either version is unbounded, or
an anchor id resolves to zero or more than one element at flush
time (libdom does not enforce id uniqueness; ambiguity declines),
the mark declines to full.

The inheritance leg, stated because constraint 4 turns on it: a
root's own style can change only if the root itself matches a
changed selector — the root is inside its own rebuild — and
inherited values flow from ancestors into the subtree, never out
of it, so an anchored change cannot alter an outside element
through inheritance. Outside elements also cannot match the
changed selectors (anchoring), and selectors in *unchanged*
sheets match exactly as before in both contexts. So no outside
element's selected style differs between the contexts, which is
constraint 4's condition.

**C. Multi-root local rebuild.** At the flush, a sheet mark with
a bounded reach expands into one precise mark per root, fed
through the existing try-local path (`macos9_reconvert_try_local_one`
and the html.c local entries), with the subtree-rebuild entry of
(b) above as the per-root mechanism. Roots are ancestor-collapsed
first (a root inside another root is subsumed by its rebuild;
document order from one tree walk). Patch 309's cost guard
applies across the whole expansion: cumulative local cost is
bounded by the avoided full reconvert's measured cost, and a
guard trip sends the remaining roots to one full reconvert —
correct by doc 20's constraint 2, and counted. The two-decline
rule is untouched: two declining roots take the batch full, as
two declining marks do today.

## Staged surface

- **Stage 1 — identity + census (instrumentation only).** Piece A
  plus a patch-308 census split of doc 20's T7 into
  sheet-single-identified / sheet-multi / sheet-unidentified.
  Identified marks still take the full reconvert. This validates
  the funnel claim (one plumbing point serves text edits, CSSOM
  and late sheets) and sizes stage 2's win on the gate suite and
  on real-shaped pages before any behaviour changes. No host win
  is claimed for stage 1; it is the stage-0 move doc 20 already
  established the pattern for.
- **Stage 2 — anchored reach + subtree rebuild.** Pieces B and C
  for the confined case that exists in this stack: sheets whose
  every selector, in both versions, is an id-anchored descendant
  chain. Gate page below. This is the first stage that may claim
  a win, and per doc 20 constraint 5 it must show one on a named
  page or not ship.
- **Stage 3 — general reach by match enumeration.** Only if stage
  2's census shows unanchored edits common enough to pay for it:
  run the changed sheet's old ∪ new selectors over the DOM with
  the engine's selector matcher, take matched elements' blocks as
  roots (ancestor-collapsed, guard-bounded as in C). Precise
  where stage 2 is conservative; priced by the census, not by
  enthusiasm.
- **Out of scope:** shadow-root and `@scope` sheets (no substrate
  — see Open questions); reach computed from libcss's compiled
  selectors (the house pattern is the textual scan; libcss
  internals were already scoped out by perf round 3); sheets
  whose change crosses documents (a sheet change in a frame child
  already marks only the child's content — per-content confinement
  holds today and this design does not touch it).

## Failure and lifetime semantics

- **Re-edit before the flush:** counter mismatch (piece A) → the
  stale mark declines to full; the newer mark carries its own
  identity and snapshot pair. Never answer from a superseded
  pair.
- **Anchor element removed between mark and flush:** roots are
  held under the referenced-node discipline (doc 20 constraint
  4); a root found detached at expansion time declines the mark
  to full — the DOM changed shape under the analysis, and the
  analysis does not get a second guess.
- **Snapshot lifetime:** the outgoing anchor list lives on the
  stylesheet entry from process time until the flush consumes or
  drops the mark (slot_drop path). Its bound is one anchor list
  per in-flight sheet mark; the pending-slot bound (patch 309's
  ring, 8 slots) bounds how many can be in flight.
- **Multi-sheet windows, unreadable source, scan failure:** all
  decline to the nodeless full reconvert, each as a counted
  census cause. No stage adds an uncounted full-reconvert path
  (doc 20 constraint 3).
- **Census regression rule (from doc 20):** a stage that makes
  any cause gain full reconverts across the gate suite has failed
  its gate even if its target page improves.

## Gate page (spec, stage 2)

`testpages/pages/CSS-sheet-scope.html`, prefix SHEETSCOPE,
modelled on CSS-style-edit (STYLEEDIT) for the restyle legs and
JS-attr-local (patch 313) for the census assertion:

1. **Anchored edit, answered locally.** A `<style>` whose rules
   are all `#panel`-rooted descendant chains; a script rewrites
   its text, changing descendants' colours. The descendants'
   computed styles and pixels change; an outside element's style
   and pixel are unchanged; the flush cause for the batch is the
   sheet-local cause with zero full reconverts after the initial
   conversion.
2. **Removal leg.** The edit deletes a rule instead: the
   previously styled descendant returns to its default, answered
   locally — the leg that proves the outgoing sheet's snapshot
   is in the bound, not just the incoming one.
3. **Unanchored edit.** The same page shape with one bare element
   selector in the sheet: the batch goes full (cause counted),
   page still correct.
4. **Mixed batch.** An anchored sheet edit plus a structural DOM
   mark in one flush: the batch follows the existing rules
   (two-decline / full as the machinery decides); final styles
   correct.
5. **Stale-pair leg.** Two edits to the same sheet inside one
   task: counter mismatch → full, final style correct.
6. **Suite invariants.** STYLEEDIT 4/4 holds; the patch-308
   census over the whole gate suite shows no cause gaining full
   reconverts against the pre-stage baseline run; interaction
   and Vita-pace counts hold.

## Cost expectation

The analysis cost is one textual scan of the changed sheet (the
sib-scan class of cost), once at process time for the outgoing
version and once through the existing per-handle cache for the
incoming one. The stress case is patch 266's: a 640 KB sheet
edited repeatedly by hydration. One scan of that text per edit
replaces, per edit, a full reconvert of the whole page — on the
5000-paragraph bench shape a full reconvert is 385–436 ms host
(perf round 3), and the guard caps the local answer at that same
cost in the worst case, so the stage cannot make an edit slower
than today by more than the scan. The expansion's bookkeeping
(root walk, ancestor collapse) is linear in the root count,
which the guard also bounds. All figures host-relative per doc
20 constraint 5; on the device factor, an anchored hydration
burst is the difference between a results page freezing per edit
and answering inside the burst.

## Open questions

1. **The confined first case.** Leg 6 named shadow-root-scoped
   sheets as the confined-by-construction case for a future
   design to take first — but this stack has no shadow DOM (no
   `attachShadow` in the bridge, no shadow-root support in
   libdom, no `@scope` in libcss), so a shadow-scoped sheet
   cannot occur and cannot be stage 2's case. This design
   re-anchors the confined case to id-anchored descendant sheets
   (confinement proved from selector text, above) and reserves
   the mark's owner identity so that if a shadow substrate is
   ever designed, its sheets enter through the same stage-2
   machinery with the root given by construction instead of by
   analysis. Owner: confirm the re-anchor — or direct that
   stylesheet scoping wait on a shadow substrate existing first.
2. **Singleton vs set.** Stage 2's plumbing pays only for
   single-sheet settle windows. Stage 1's census will say how
   common multi-sheet windows are on real-shaped pages; if they
   dominate, identity must carry a small set of (entry, counter)
   pairs instead, which is more pending-record state to bound.
   Flagged here so the choice is made on census data in the
   open, not silently inside a patch header.

## Status (2026-10-25): stage 1 census landed as patch 316

Census only: batch-level attribution through per-entry counters in
css.c, with no identity on the mark (piece A's mark variant is
deferred to stage 2). First readings: across the gate suite, 9
nodeless batches, single=8 / multi=1 / unidentified=0. There is a
new cost the design did not price: each `<style>` edit takes **two**
full reconverts, because the edit's own precise mark on the style's
text node is declined by the local path before the sheet's nodeless
batch arrives. Stage 2 has to answer (or deliberately absorb) that
text-node mark as well, or it saves at most half. Details are in
doc 10's patch 316 entry.

## Status (2026-10-25, later): piece A landed as patch 318

Sheet identity rides on the mark (`macos9_js_mark_dom_dirty_sheet`,
index + per-entry modification counter), folded per batch and checked
at the flush (single / stale / multi / none). Behaviour unchanged; the
batches still take the full reconvert. One reading of the text above:
"entries processed since the last mark" is implemented as "entries in
flight" (queued or loading), because the initial parse processes
entries without ever marking. Gate suite: single=8 stale=1 multi=1
none=0. Pieces B (reach) and C (local answer) are not started.
