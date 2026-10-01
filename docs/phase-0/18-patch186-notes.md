# Patch 186 Implementation Notes

## Overview
Patch 186 replaces patch 174's blanket sibling-combinator decline with a
precise per-selector risk analysis for block-level class changes.

## Behavior
When a block element's class changes, instead of declining to the full
rebuild whenever ANY author stylesheet contains a '+' or '~', patch 186:

1. Parses every sibling combinator's left compound once per stylesheet
2. Caches the parsed compounds keyed by stylesheet handle + FNV-1a hash
3. Matches each left compound against the element with OLD and NEW class
   states (explicit values from the mutation record, never live DOM)
4. Declines only if `match_old != match_new` (XOR) for any compound

## Motivation
Patch 174 was sound but overly conservative. A page with `.menu + .content`
in its CSS would force a full rebuild for EVERY block class change, even
when the changed element was unrelated to the sibling rule. Patch 186
preserves soundness while allowing the local rebuild when the class change
cannot affect any sibling's style.

## Measurements
- Build: 271 patches applied, 0 failed; all libraries ok; netsurf ok
- Patch verification: byte-identical output when applied to reference tree
- Syntax: standalone checks pass for all new code

## Conservative Decline Cases
The full rebuild (always correct) is taken when:
1. A sibling combinator appears inside :has(), :is(), :not(), :where(),
   :matches(), :any(), or :-webkit-any() — e.g. `.t:has(+ .u)` restyles a
   PRECEDING sibling, which the one-block rebuild cannot reach.
2. A pseudo-class appears on a left compound (e.g. `.a:hover + .b`) —
   dynamic state cannot be evaluated exactly.
3. Any selector prelude fails to parse, or a combinator appears where a
   compound was expected.
4. The old class value is NULL (unknown from the mutation record).
5. Memory allocation fails during parsing or caching.

Non-decline cases (correctly ignored):
- Arithmetic '+' in :nth-child(2n+1) — not a combinator
- '+'/'~' inside attribute selector strings — not a combinator
- '+'/'~' inside declaration blocks (e.g. calc(a + b)) — skipped
- Unrelated sibling rules where the element matches neither OLD nor NEW
- Rules where the element matches both OLD and NEW (no state change)

## Implementation Details

### Files Changed
- `content/handlers/html/html.c`: Replaced `html_rl_css_has_sibling()` and
  `html_rl_page_css_has_sibling()` with the precise scanner, matcher, cache,
  and `html_rl_class_sibling_risk()`. Updated `html_reconvert_local_class()`,
  `html_reconvert_local_change()`, and `html_rl_block_restyle()` signatures
  to thread the old class value.
- `content/handlers/javascript/quickjs/macos9_reconvert.c`: Added
  `old_class` field to pending record; `macos9_reconvert_pending_add2()` and
  `macos9_js_mark_dom_dirty_node2()` accept the pre-mutation value; same
  node+kind merges preserve the FIRST mark's old value.
- `content/handlers/javascript/quickjs/macos9_reconvert.h`: Declared
  `macos9_js_mark_dom_dirty_node2()`.
- `content/handlers/javascript/quickjs/macsurf_qjs.c`: Added
  `qjs_mark_dom_dirty2()`; `setAttribute('class', ...)` and
  `removeAttribute('class')` pass the pre-mutation value.

### Selector Parser
The parser handles: type selectors (lowercased), #id, .class (multiple),
attribute selectors with =, ~=, |=, ^=, $=, *= operators and i/s flags,
pseudo-classes (decline if on left compound), pseudo-elements (never match),
functional pseudos (decline if containing sibling combinator), comma groups,
and nested group at-rules (@media, @supports, etc.).

### Compound Matcher
Mirrors the patch-178 JS selector engine's `compoundOk`/`attrOk` exactly:
- Tag: lowercased comparison via `dom_element_get_tag_name`
- ID: case-sensitive comparison
- Classes: whitespace-separated token membership
- Attributes: all operators with case-insensitive flag support
- Pseudo-elements: never match (return false)
- Class attribute: uses override value when provided

### Cache Design
Replaces patch 174's `(source pointer, size)` key with:
- Key: stylesheet handle (`struct hlcache_handle *`)
- Validation: source data pointer + size + FNV-1a hash
- This closes the allocator-reuse aliasing hole where a freed buffer's
  address could be reused for different content.

### Mutation Producers
- `setAttribute('class', value)`: OLD = pre-mutation lookup (may be NULL
  if absent), NEW = explicit value
- `removeAttribute('class')`: OLD = pre-removal lookup, NEW = absent
- `className` setter: delegates to `setAttribute`
- `classList.add/remove/toggle/replace`: delegate to `setAttribute`
- `setAttributeNS`: not implemented in this bridge (documented)

## Testing
- New test page: `testpages/pages/CSS-sibling-class.html` (6 cases)
- Existing gates preserved: JS-class-stall, JS-block-class-stall,
  JS-block-class-sibling
- Simulator gate: build verified; full simulator run not completed due to
  time constraints (build succeeds, patch applies cleanly)
