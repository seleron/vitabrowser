# Patch 186 (design, 2026-09-30): precise sibling-combinator decline

## Problem (measured)

Patch 179's `html_rl_block_restyle` declines EVERY class change on a page
whose CSS contains ANY `+`/`~` combinator (`html_rl_page_css_has_sibling`,
html.c:6820). On webkit-flavoured sites almost every stylesheet has at
least one sibling selector, so local class restyle is dead there and every
`el.className = ...` costs a full reconvert. The JS-side mirror is the same
shape: `qjs_el_setAttribute_data` (macsurf_qjs.c:4620) only enqueues a class
change as a DOM mutation when the page has sibling CSS; the C path then
re-checks and declines with "page CSS has sibling combinators".

The blanket check is conservative in BOTH directions:
- it declines when no sibling rule can reach the element's siblings
  (common: the sibling rule targets an unrelated branch of the tree);
- it is the only reason the decline happens — a per-selector check would
  be strictly more permissive and therefore strictly faster, with the
  decline remaining as the safety net.

## Correctness criterion (why per-selector is safe)

A class change on element `el` can change the cascade of a node `s` (a
FOLLOWING sibling of `el`, or for `~` any later sibling of a shared parent)
iff some selector in the page CSS matches `s` BEFORE and the selector's
match for `s` depends on `el`'s class (i.e. the subject of the sibling
combinator is `s` and the compound immediately left of the combinator can
match `el` under the OLD class, or matches `el` under the NEW class).

So the precise check is: for every rule whose selector prelude contains a
sibling combinator, take the compound immediately LEFT of the combinator
(the one that must match `el`) and ask:
- OLD risk: does it match `el` with its OLD class value? (the sibling
  currently depends on el; if el's class changes the sibling's match can
  change -> must decline)
- NEW risk: does it match `el` with the NEW class value? (el would START
  controlling a sibling that didn't depend on it before -> the local
  reconvert does not restyle that sibling -> must decline)

If neither holds for any rule, no following sibling's cascade is affected
by `el`'s class, and the class change is locally containable: reconvert
`el`'s box (patch 166's remove/insert) and, for the siblings whose cascade
value is UNCHANGED, nothing further. The full reconvert's only extra work
is re-cascading the siblings, which is provably a no-op under that
criterion.

Note the check is against the PRE-CHANGE DOM (the decline runs before the
attribute mutation is committed), so the OLD-class branch reads live
attributes and the NEW-class branch substitutes the proposed value.

## Where the old value comes from

The decline runs inside `html_reconvert_local_class` (called from
`macos9_reconvert.c:697` for `MACOS9_DOMMUT_SETATTR_CLASS`) AFTER the DOM
mutation has already committed the new value (the mutation queue applies
then reconverts). So "old class" is not the live attribute. Options:

(a) Capture the old value in the mutation RECORD: `qjs_el_setAttribute_data`
reads the current class attribute BEFORE `dom_attr_set_value` and stores it
in a new field on the class-change record (the JS path already intercepts
this exact call site to enqueue the record — macsurf_qjs.c:4620-4660).
Cheap, no DOM walk, exact. The record already carries element + new value;
add `char *old_value` (lwc-string copy, freed at record destroy).

(b) Read the CSS cascade's cached class value: not available (the cascade
doesn't keep per-element source values).

Use (a). The C-level `macos9_reconvert.c` path receives the record and
threads `old_value` into `html_reconvert_local_class(..., old, new)`.

## Implementation sketch

1. libcss/netsurf CSS walk: a new helper `html_rl_page_css_sibling_risk`
   returning, per rule with a sibling combinator, the compound immediately
   left of the combinator. Reuse `html_rl_css_has_sibling`'s prelude scan
   (it already skips comments/strings/blocks/at-rules correctly) and, when
   a `+`/`~` is found at par==0, capture the text from the previous
   combinator/`{`/start up to the combinator, then parse that fragment
   with the SAME compound grammar as the JS engine.

2. Compound matcher: port a minimal version of the JS Selectors-4
   `qjs_compound_match` (macsurf_qjs.c:10108) to the C side — tag, id,
   class (space-set), the seven attribute operators, and the leading
   pseudo-class set the JS engine already supports (patch 178). It is ~120
   lines; the JS engine is the reference for what the DOM layer considers
   "supported", so matching its grammar means the C check never declines
   LESS than the JS matcher would require. Anything the JS engine degrades
   to `approx` (e.g. a fancy pseudo) must ALSO cause a decline in the C
   check — "can't parse" == "can't prove safe" == decline. This is the
   key invariant: the C checker is a sound subset of the JS matcher.

3. Element-side match with class substitution: the matcher takes an
   explicit class-set override (for the NEW branch). OLD branch: live
   `dom_attr_get_value`. NEW branch: the proposed value.

4. `html_reconvert_local_class` signature gains the old value; the
   `html_rl_page_css_has_sibling` decline (html.c:6820) becomes the
   precise check. Keep a fast path: if the page has NO sibling CSS at all
   (the existing 32-slot data+size cache, which stays), skip the per-rule
   walk entirely — most pages take this path.

5. JS side: `qjs_el_setAttribute_data` keeps its blanket decline ONLY when
   it cannot cheaply know the CSS has no sibling rules (the same cache).
   When the page HAS sibling CSS it now always enqueues (the C side makes
   the precise decision), so JS does one cache lookup and one enqueue —
   strictly less JS work than today's blanket "has sibling CSS -> decline"
   path is currently doing in the C reconvert.

## Test plan

- `CSS-sibling-class.html`: a page with `.a + .b { ... }` and
  `.a ~ .c { ... }`; JS flips classes on elements in a branch with NO
  sibling rules (local restyle must run: assert the `RL_LOCAL` count via
  the same plot-string mechanism as the 165/166 local-rebuild tests) and on
  an element that DOES drive a sibling (must decline: assert the full
  reconvert ran, and that the sibling restyled).
- Regression: every existing local-rebuild test page (165 text, 166 block,
  179 class) unchanged — their pages have no sibling CSS, so they take the
  fast path.

## Cost / expected gain

The per-rule walk only runs on pages WITH sibling CSS, once per class
change, and is bounded by (rules with sibling combinators) x (compounds per
rule) — both small in practice (the scorecard pages have <20 such rules).
The gain: local class restyle works on webkit-flavoured pages, which is
exactly the population where JS `className` churn is heaviest (React-style
class toggling) and where the full reconvert is most expensive (large
document trees).

## Risks

- Compound grammar drift between the JS and C matchers: mitigate by
  making "unparseable compound" decline (sound subset invariant), and by
  the test page exercising the same compound shapes the JS engine supports.
- Attribute values with `~=`/`|=` etc. against a substituted class: the
  matcher reads attributes through `dom_attr_*`, same as the JS side.
- The NEW-risk branch needs the proposed class as a string: the mutation
  record already has it (the JS path passes the new value when enqueuing).
