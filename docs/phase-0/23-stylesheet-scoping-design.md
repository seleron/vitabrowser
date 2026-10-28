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

## Piece B design (2026-10-27): reach from changed rules, anchored on any compound

Design only: no implementation, no patch. This pass checked piece B
(above) against real sheets and the code it has to fit, before any
patch. Two of its premises do not hold. This section replaces piece B's
definition, and it replaces the confined case of open question 1.

### Evidence: the id-anchored confined case does not occur on real pages

The inline `<style>` sheets of two CSS-in-JS front pages were fetched
on 2026-10-27 (theguardian.com/uk 1.6 MB HTML, 20 sheets; bbc.co.uk/news
0.9 MB, 4 sheets). Each style rule was classified textually. These are
host Python measurements; the scanner was rough around parenthesised
`@supports` preludes, which account for about 8 rules. In the `dcr` sheet, 3 of
the 4 "unanchored" readings and all 8 at-rule/nesting readings are that
artifact.

| rule shape | Guardian, all sheets (1352 rules) | Guardian `dcr` sheet (764 KB, 1248) | BBC, all (1192) | BBC largest (1153) |
|---|---|---|---|---|
| every selector's **leftmost** compound has a plain `#id` | 0% | 0% | 0% | 0% |
| a valid **class or id anchor** (rule below) | 95.4% | 99.0% | 96.7% | **100%** |
| no valid anchor (bare tags, `:root`, `*[hidden]`, a reset list) | 1.6% | 1 rule | 0.9% | 0% |
| at-rules (`@font-face`, `@keyframes`) | 2.7% | 0.3% | 2.3% | 0% |

Piece B as written needs a whole sheet of id-anchored descendant
chains. On these pages that never happens: no sheet qualifies and no
edit would ever be answered locally. Two changes fix that, and each is
needed on its own terms:

1. **Anchor on classes as well as ids, at whichever compound is valid.**
   CSS-in-JS emits hashed class selectors (`.dcr-1lp5d41`,
   `.ssrcss-k49uhy-PromoContent`), and almost none carry an id.
2. **Bound only the rules that changed, not the whole sheet.** Even
   with class anchors, the Guardian's `dcr` sheet is unbounded as a
   whole, because of a single rule (`.dcr-1lp5d41:focus~button`). A
   hydration edit appends rules and leaves that one untouched.

### B.1 Anchors (replaces "Anchored / Unbounded" above)

A selector is a chain of compounds C0 c1 C1 ... cn Cn, where Cn is the
subject. A compound Ck is a **valid anchor** when it carries a plain
`#id` or `.class`: outside any functional pseudo, so `:is(.a)` and
`:not(.a)` do not count. One of these must also hold:

- Ck is the subject (k = n). Every element the selector matches
  carries the token.
- The combinator **immediately to Ck's right** (c(k+1)) is
  descendant or child. The element matched at C(k+1) is then inside
  Ck's element's subtree. Each later sibling step stays under a
  parent that is already inside that subtree, and each later
  descendant or child step goes further in. So every match lies in
  the subtree of an element carrying the token, whatever c(k+2)..cn
  are.

The selector's anchor is the **rightmost** valid compound, which gives
the tightest reach. Within one compound an id is preferred over a
class. A selector with no valid anchor is unbounded. One unbounded
selector in a rule's list makes that rule unbounded.

This corrects two statements in piece B above:
- "Every combinator in the selector is the descendant combinator" is
  stricter than needed. A child combinator confines just as well, and
  so does a sibling combinator to the right of a downward step:
  `.Stack > * + *` is bounded by `.Stack`.
- Only `#a ~ x` / `#a + x` (a sibling step directly right of the only
  anchor) escape.

What the Guardian and BBC sheets look like under this rule:
- `html:not(.x) .dcr-a:focus` anchors at `.dcr-a` (the subject).
- `#cb:checked~div .dcr-b` anchors at `.dcr-b`.
- `.ssrcss-…-Stack >*+*` anchors at `.ssrcss-…-Stack`.

### B.2 Changed rules, old ∪ new (replaces the whole-sheet bound)

Both versions of the sheet are split into **records**. A record is one
style rule, identified by the text of its enclosing group preludes, its
selector text and its declaration block, with comments removed and
whitespace runs collapsed. Each record is reduced to a 32-bit FNV-1a
hash, the house hash already used by `html_rl_sib_sheet_for`. The
changed set is found by trimming the longest common prefix and the
longest common suffix of the two hash sequences. What is left in the
middle of each version is the changed rules: the outgoing middle (old)
and the incoming middle (new). The reach is the union of the anchors of
every changed rule in both versions (constraint 4).

**Why this is sound** (constraint 4, for rules rather than sheets):
- Take an element that no changed rule matches in either version.
  Every rule that matches it is a common record. Common records occur
  in the same relative order in both versions, because prefix and
  suffix trimming preserves order and the middle holds no common record
  by construction.
- Selectors in other sheets are unchanged.
- So that element's matched declarations are the same, in the same
  cascade order, under both selection contexts, and its cascaded style
  is identical.
- Inheritance only flows into a root's subtree, as piece B already
  argued.
- Hence no element outside the anchors' subtrees changes style.

A middle that holds a rule and its moved copy is merely conservative:
both copies count as changed.

**The change is unbounded (full reconvert, cause counted) when:**
- **Any changed record is not a plain style rule.** That covers
  `@import`, `@namespace`, `@font-face`, `@keyframes`, `@property`,
  `@counter-style`, `@page`, statement-form `@layer a, b;` (layer order
  is document-wide, across sheets) and any unknown at-rule. All of
  these reach elements by name, not by selector.
- **A changed rule's declarations mention `counter-increment`,
  `counter-reset`, `counter-set`, `counter(` or `counters(`.** This
  engine keeps one flat counter table per box-construction pass
  (box_construct.c, fixes134b), so a counter change inside a subtree
  renumbers generated content after it, outside the subtree. This is
  patch 192's token list, for the same reason.
- **A changed rule contains a nested block** (CSS nesting, patch NEST211).
  `&` placement can move the anchor, and v1 does not follow nesting.
- **There is a backslash anywhere in a changed rule's prelude**, as in the
  existing scan.
- **A group prelude cannot be parsed**, or the sheet has no source data.
- **More than a fixed number of changed records** (proposed 64, set from
  the stage-B1 census): bookkeeping past that costs more than it saves.

Rules that did not change are never classified. The Guardian's one
sibling-escaping rule does not stop an edit that leaves it alone.

### B.3 Snapshot: a record table per stylesheet entry, handed on edit to edit

The outgoing version's source is released inside
`html_css_process_modified_style` (the old handle dies at the swap). So
the old side must be captured there, as piece B said. What is captured
changes: a **record table**, not an anchor list. The table holds each
record's hash and the offset of its anchor tokens in a pooled string
block.

- **Where it lives:** two owned pointers on `struct html_stylesheet`,
  `reach_cur` (the table of the live version, when computed) and
  `reach_prev` (the table of the version the boxes were built with).
- **At process time:** `reach_prev` takes `reach_cur` when it exists.
  Otherwise the outgoing source is scanned once, before the release.
  `reach_cur` is then emptied, and the incoming version's table is
  built lazily at the flush from the new handle's source (it is done by
  then: the mark only fires when the sheet finishes).
- **The handoff:** after a flush, the incoming table becomes the next
  edit's `reach_prev` without a rescan. A sheet edited N times is
  scanned N+1 times in all, once per version, never twice per version.
  Sheets that are never edited are never scanned.
- **Lifetime:** freed with the entry, and replaced at each process. A
  stale mark (counter mismatch, patch 318) declines before the tables
  are read, so a superseded pair is never used (unchanged rule).
- **Bound:** two tables per edited sheet. The Guardian `dcr` sheet is
  about 1250 records, roughly 10 KB of hashes and offsets plus about
  12 KB of anchor tokens. That is small next to the 764 KB source that
  libcss re-parses on every edit anyway.

This replaces "ids only, freed when the mark it fed is consumed".
Holding the old handle until the flush would avoid the scan, but it
would also keep the old parsed libcss sheet (several times the source
size) alive per in-flight mark, which is the wrong trade on the Vita.

### B.4 Resolving anchors to roots at the flush

The anchor tokens of the changed rules form a small set of ids and
classes. They are resolved in **one document-order walk**, which is the
walk piece C needs anyway:
- **Same predicates as the matcher.** Ids are compared exactly, as
  `node_has_id` does (case-sensitive even in quirks mode).
  Classes go through `dom_element_has_class`, which is case-insensitive
  whenever the document is not in no-quirks mode (libdom tests
  `quirks_mode != NONE`). Re-implementing either comparison would let
  the bound disagree with the matcher.
- **Ancestor collapse in the same walk.** A matching element becomes a
  root and its subtree is skipped.
- **Several elements with one token are expected.** A class names many
  elements, and libdom does not enforce id uniqueness. This is a union,
  so piece B's "an id resolving to more than one element declines" is
  dropped. The root count is bounded instead (patch 309's guard, in C).
- **A token matching no element contributes no root.** If the batch
  holds only this sheet mark, the DOM is the one the boxes were built
  from, so no element carried the token under the old context either. If
  the batch holds other marks, they keep their own rules (two-decline),
  and an element whose class or id changed is rebuilt by its own
  attribute mark (patch 313).

### B.5 Root admission (the contract handed to piece C)

These conditions turn a root's subtree rebuild into effects outside the
subtree. If any one holds, the whole batch takes the full reconvert:
- **The root is `<html>` or `<body>`.** Their background, overflow and
  direction propagate to the canvas and viewport, and a full reconvert
  costs the same anyway.
- **The root is a list item, or the child of `ol`/`ul`/`menu`.** The
  implicit list-item counter numbers following siblings during box
  construction.
- **The root's display is `contents` or `none` in either context, or
  changes between `inline` and block level.** In those cases the root
  has no box of its own to replace, or the parent's anonymous boxes
  change. C checks the new computed display against the old box type.
- **The root has no box while being displayed** (an unconverted
  subtree).

### B.6 The companion text mark (the second full reconvert per edit)

Patch 316 found that each `<style>` text edit costs two full reconverts.
The precise mark on the style's text node is declined by the local path,
and then the sheet's own batch arrives.

**Rule:** a precise mark is absorbed, meaning dropped and counted rather
than declined, when all three hold:
- Its node is a child of an HTML `<style>` element, or the mark is that
  element's own child-list mark.
- The `<style>` element has no box (`box_for_node` is NULL, which is
  the UA sheet's `display:none`).
- The mark is not a structural mark that moves the `<style>` itself.

**Why it is sound:** a node under an unboxed element has no box, so
rebuilding for it changes no box. The mark's only effect is through the
sheet, which `DOMSubtreeModified` → `html_css_update_style` handles on
its own path and marks separately. This does not depend on the sheet
mark following. If the reparse fails, there is still nothing to rebuild.

**What it is worth:** it saves one full reconvert per `<style>` edit
(the first one, which today rebuilds against the old, unchanged sheet,
so it is wasted outright). It is independent of reach and C. A `<style>`
an author made visible (`style{display:block}`) has a box and keeps
today's path.

### Staging (replaces stage 2's single step)

- **B0: absorb the companion text mark (B.6).** This is a behaviour
  change with its own gate leg: STYLEEDIT 4/4 and SHEETCENSUS 3/3 hold,
  and the census shows one full reconvert per edit instead of two. It
  is the first host win on the doc 20 constraint 5 terms, measurable on
  CSS-style-edit and JS-sheet-census.
- **B1: reach census.** B.1 through B.4 and B.5's static checks, with
  the full reconvert unchanged. Every single-identified current sheet
  batch logs one of:
  - `LIFE SHEETREACH bounded changed=K anchors=A roots=R walked=N`
  - `LIFE SHEETREACH unbounded reason=<at-rule|counter|nesting|escape|unanchored|too-many|admission|no-source>`

  These feed a `SHEETREACHCENSUS` beside `SHEETIDCENSUS`. Run on the
  gate suite and on the scorecard's CSS-in-JS sites (the Guardian, BBC,
  claude.ai) in the simulator, plus the run-40 device logs. **C is built
  only if bounded batches dominate**, and C's guard budget is sized from
  the R and N readings.
- **C: multi-root rebuild,** unchanged from piece C above. It is fed by
  B1's root set, with B.5 as its admission contract.

### Gate page additions (extends the stage-2 spec above)

These are SHEETSCOPE legs. Every leg also asserts final computed styles
against Chromium.

1. **Class-anchored append**, the CSS-in-JS shape: a script appends
   `.k1 .x{color:...}` to a large `<style>` through `insertRule`. B1
   logs `bounded changed=1`, and the roots are the `.k1` elements.
2. **The subject is anchored behind a sibling step:**
   `#cb:checked ~ div .y` is bounded at `.y`. `.y ~ button` is unbounded
   (`reason=unanchored`).
3. **Removal:** deleting an anchored rule includes its anchor (from the
   old side) in the root set.
4. **A common rule left alone:** a sheet holding one global
   `body{...}` rule, plus an edit elsewhere, stays bounded.
5. **Unbounded causes,** one leg each: an `@font-face` added, a
   `counter-increment` rule, a nested rule, a statement `@layer`, and an
   edit to the global `body{}` rule itself.
6. **Quirks-mode class case:** in a document without a doctype,
   `.Foo` anchors elements with `class="foo"` (matcher parity).
7. **Admission:** a root that is an `li`, and a root that is `<body>`,
   are bounded by B1 but declined by B.5.
8. **B0:** a `<style>` text edit produces one full reconvert, not two.
   A visible `<style>` (`display:block`) still repaints its text.

### Open questions (for the owner)

1. **Confirm the re-scope.** The confined case becomes "the changed
   rules all have class or id anchors", not "the whole sheet is
   id-anchored". The measurement above is the reason. The shadow-DOM
   reservation in open question 1 above stands unchanged.
2. **B0 first?** It is the cheapest win in this design, it needs no part
   of reach, and it halves every `<style>` edit today. The
   recommendation is to land it before B1.
3. **The changed-record cap** (proposed 64) and whether B1 should also
   log the changed-record count of batches it declines. That would show
   whether a hydration burst ever exceeds the cap.

## Status (2026-10-27): piece B0 landed as patch 320

The re-scope (any-compound anchoring, changed-rule bounding) was
approved by the user 2026-10-27: "re-scope approved, land B0 first,
cap 64 is fine". B0 landed as patch 320 (built solo by Hermes; Claude's
final turn wrote the C, the takeover verified it clean), as designed
in B.6, with two recorded deviations:

- The absorb condition also refuses a `<style>` whose ancestor chain
  renders from the DOM instead of boxes (inline `<svg>`, `<math>`, and
  the form gadgets select/option/optgroup/datalist/textarea). Their
  text is painted from the DOM, so an edit does change the paint there;
  those marks keep the old path. See the `reads_dom[]` table in html.c.
- The spec's "a visible `<style>` (display:block) still repaints its
  text" is untestable in this engine: box building skips `<style>` by
  tag name, so it can never have a box. The C-side box-existence guard
  keeps the old path for any `<style>` that does get a box, and a
  refused mark is logged (`LIFE STYLETEXT refused reason=...`).

First reading: a `<style>` text edit now costs one full reconvert
(the sheet's own nodeless batch) instead of two; the companion mark's
own reconvert -- which rebuilt the tree against the old, unchanged
sheet -- is absorbed and counted (`LIFE STYLETEXT absorbed`,
`LIFE STYLETEXTCENSUS` at navigation reset; parse-time marks are not
counted, so the counter starts at zero). The new gate page
JS-style-absorb.html (STYLEABS 4/4) covers a textContent set, a CSSOM
insertRule (its writeback goes through the text mark), a text node's
data, and a mixed `<style>` + paragraph task. SHEETCENSUS is unchanged
(3/3, the multi and stale legs intact).

The first full gate (gate-320) failed, and the diagnosis was a harness
timing race, not a patch regression: both JS-leg pages are exactly one
screen tall, so the autotest dumped them at the top settle (~700 ms
after the first repaint). This engine's JS timers run ~450 ms late, so
the 1500 ms legs fired after the dump and the plots showed the initial
state (0/4 and 0/3). The fix follows the existing JS-attr-local
pattern: a 7000 px spacer makes each page taller than the screen, so
the bottom pass is taken, whose 7 s settle window covers the legs; the
gate now reads the `*-bottom.plot` of these two pages.

## Status (2026-10-27, later): piece B1 implemented, not yet gated

The B1 census engine (B.2 diff, B.3 capture, B.4 walk, B.5 admission,
reason priority) is fully written into css.c and wired into
macos9_reconvert.c (`LIFE SHEETREACH` per event beside `LIFE SHEETID`,
`LIFE SHEETREACHCENSUS` at the flush). Both touched objects compile
clean in the applytest tree (Hermes solo build). Remaining before this
piece can be called landed: the SHEETSCOPE gate page, its
`run-vita-sim.sh` registration, the full gate, and the 321 patch file
(order in `~/vitabrowser-work/B1-handoff.md`). Census only — no
behaviour change, so the existing 320 gate expectations are untouched
by design.

## Status (2026-10-28): piece B1 landed as patch 321

B1 is in, as specified (B.1 through B.4, plus B.5's static checks), and
is census only. Each single-identified current sheet batch logs
`LIFE SHEETREACH bounded changed=K anchors=A roots=R walked=N` or
`LIFE SHEETREACH unbounded reason=<cause>`, and the navigation reset
prints `LIFE SHEETREACHCENSUS bounded=.. unbounded=.. <cause>=..`. The
full gate passed (gate321, exit 0), with STYLEABS 4/4 and SHEETCENSUS
3/3 unchanged. Doc 10's patch 321 entry has the five defects that the
review fixed in the solo-built engine before the gate.

**Gate legs (SHEETSCOPE 5/5, SHEETSCOPE-UNB 5/5, SHEETSCOPE-Q 3/3).**
Every leg of the gate-page spec above has a leg except B0's (already
covered by 320's STYLEABS). Each one reads as specified:

| leg | reads |
|---|---|
| 1 class-anchored insertRule append | `bounded changed=1 anchors=1 roots=3` |
| 2 `#cb:checked ~ div .y` | `bounded changed=1 anchors=1 roots=2` |
| 2 `.y3 ~ div` | `unbounded reason=unanchored` |
| 3 removal | `bounded changed=1 anchors=1 roots=1` (anchor from the old side) |
| 4 common `body{}` left alone | `bounded changed=2 anchors=1 roots=1` |
| 5 `@font-face` / counter / nesting / statement `@layer` / the `body{}` rule itself | at-rule / counter / nesting / at-rule / unanchored |
| 6 quirks `.Foo` vs `class="foo"` | `bounded changed=1 anchors=1 roots=1` |
| 7 `<li>` root, `<body>` root | `unbounded reason=admission` (both) |

Census lines: JS-sheet-scope `bounded=4 unbounded=1 unanchored=1`;
JS-sheet-scope-unb `bounded=0 unbounded=5 at-rule=2 counter=1
nesting=1 unanchored=1`; JS-sheet-scope-quirks `bounded=1 unbounded=2
admission=2`. All three read `no-source=0`.

**Deviations from the design, recorded:**
- **Leg 1's roots are the `.x` elements, not the `.k1` elements** as
  the gate-page spec says. B.1 takes the rightmost valid compound, and
  in `.k1 .x` that is the subject, `.x`. The spec line contradicts B.1,
  and the code follows B.1.
- **The incoming table is built eagerly** at the processed edit, from
  the `<style>`'s DOM text, not lazily at the flush (B.3). Each version
  is still scanned once. The lazy build belongs with C.
- **The legs are split across three pages** at 1200 ms per leg,
  because the bottom-settle window holds about five legs.
- **No legs exist for `escape`, `too-many` or `no-source`.** The gate
  instead asserts `no-source=0` on all three pages. That catches a
  first-edit capture that loses the old source, which the solo build
  had.

**Census over the whole gate suite (178 network pages):** 26 events,
16 bounded and 10 unbounded. Outside SHEETSCOPE, the only unbounded
events are CSS-late-link (`no-source`, a `<link>` sheet) and
HTML-embed-placeholders (`too-many`: a YouTube iframe's `<style>`
arriving whole into an entry with no prior sheet). The largest bounded
reading was K=2, R=3, N=3066.

**What decides C.** The gate pages are synthetic and do not count
toward "bounded batches dominate". The deciding census is:
- the scorecard's CSS-in-JS sites in the simulator (the Guardian, BBC,
  claude.ai);
- the next device run, whose logs carry `SHEETREACH` per event.

C is built only if most of those real-site edits read bounded. Its
guard budget is then sized from their R and N readings.

## Status (2026-10-28, later): the real-site census, and what it says about C

The B1 census was run on the scorecard's three CSS-in-JS sites in the
simulator: `tools/scorecard/scorecard.py --only guardian,bbc,claude
--settle 30000`, reusing the r58 reference, output in
`~/vitabrowser-work/score/census-321`. All three loaded. Their visual
scores match r58 (BBC 0.734 vs 0.728, Guardian 0.515 vs 0.521,
claude.ai 0.465 vs 0.465). The news sites' text scores fell only
because the two-week-old reference has different headlines.

| site | full reconverts | sheet batches (identity) | SHEETREACH |
|---|---|---|---|
| Guardian | 5 | 1 (none) | none |
| BBC | 5 | 3 (2 single, 1 none) | 2 bounded: K=1 A=1 R=15 N=1863; K=4 A=3 R=1 N=1866 |
| claude.ai `/login` | 13 | 5 (4 multi, 1 none) | none |

**Reading.** On these pages, sheet edits are rare. All 8 single-sheet
readings in this sample came from BBC, and both of BBC's single-sheet
edits read bounded. But the sample is two events. Neither the Guardian
nor claude.ai produced a single-identified sheet batch at all.
claude.ai's sheet work arrives as two-sheet batches, which B1 does not
classify and C as designed would decline (two-decline). The 2026-10-27
design measurement predicted hydration appends to large class-anchored
sheets. That does not show up within 30 s in this engine. The most C
could remove here is 2 of 23 full reconverts, all on BBC.

**Recommendation: do not build C yet.** "Bounded dominates" holds
(2/2), but on too few events to size anything, and the payoff it could
buy on these sites is about 10% of full reconverts. Next:
- **Run 40 (device):** carry the census and read `SHEETREACH` and
  `SHEETIDCENSUS` from real browsing. Interaction, not first load, is
  where CSS-in-JS inserts rules.
- **If multi-sheet batches dominate** there, as on claude.ai, the
  question becomes whether C should take a batch of several identified
  sheets (the union of their roots). That is a design change to piece
  C's two-decline rule, and it is for the owner.

**Side finding, outside B1.** Run alone through `run-live-sites.sh`
(15 s minimum, no `VITA_CSSGAP`), the Guardian spent about 130 s of CPU
in one QuickJS timer callback before a document appeared. In gdb, that
callback was a `Proxy` get / `Reflect.get` / `Array.prototype.every`
chain calling `getAttribute` (`macsurf_qjs_run_timers`), so it is a
script-cost problem, not census code. The scorecard run of the same
page loaded. Worth its own look before the next Guardian scorecard.
*Resolved by patch 322 (doc 10). The cost was the polyfill's form
named-access wrappers (patch 305) running the full control search on
every generic member read of a `<form>`. The Guardian's title now
appears at 4.1 s instead of 207 s.*

## Status (2026-10-28, end of day): piece C still waits on the device census

There is no device census yet. Run 40 (VPK `d2008e91051c`, patches
through 324) carries the B1 census and was handed off at 20:25, but no
results have arrived (doc 10, "Run 40 — results check"). The census
lines are written only to the Vita's `netsurf.log`, so that file has to
be fetched from the device (the `results\` receiver, or USB/FTP). The
plot dumps cannot stand in for it. Until then, the real-site reading
stands: the simulator census found 2 single-identified sheet batches
across the Guardian, BBC and claude.ai, both bounded. That is too few
to decide C, which stays on hold.
