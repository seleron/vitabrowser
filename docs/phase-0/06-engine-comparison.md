# Phase 0 — measuring the patch stack with plot streams

**Date:** 2026-09-21 (updated 2026-09-22, five times: dom-walk discovery + grid/tag-type ports + gradient plotter + box-shadow plotter + animation-timeline plotter)
**Covers:** `04-patch-stack.md` §8 item 2 — the first real use of the §14.3 harness
**Status:** ✅ `nsmonkey` builds against the patched engine, author CSS now
renders, **CSS grid + form-control tag-types are live** (patches 23+24),
**linear gradients band** (patch 25), **box-shadows render** (patch 26),
**animation timelines (rotate/scale/opacity) render** (patch 27),
and **L1 is byte-identical to the pristine golden.** L2/L3/L4 differ only
where the patch stack adds behavior the pristine engine lacks.

> **Headline (2026-09-22, fifth pass):** After (1) fixing the
> `css_error_from_parserutils_error` stub, (2) replacing the no-op
> `html_css_discover_stylesheets` stub with a real DOM walk (§6), (3)
> promoting the `layout_grid` + `macsurf_html_element_get_tag_type` weak
> no-op stubs to their real MacSurf implementations (§6b, patches 23+24), and
> (4) adding the two-stop linear-gradient plotter to monkey (§6c, patch 25),
> (5) adding box-shadow rendering to monkey (§6d, patch 26), and (6) adding
> the animation-timeline plotter — rotate/scale as a 4-corner polygon,
> opacity as a bucket tag (§6e, patch 27) —
> the patched engine renders all author CSS (inline `<style>` and `<link>`),
> lays out MacSurf's `-macsurf-grid`, renders `<select>`/`<input>` controls,
> bands linear gradients, paints box-shadows (drop = offset rect,
> inset = edge bands — MacSurf's own plotters use the same primitives,
> no blur on either side), and transforms/animates boxes. L1 matches the
> pristine golden byte-for-byte.
> The remaining L2/L3/L4 diffs are the value functions, MacSurf's proprietary
> grid dialect, and layout reflows the stack is *meant* to add — not
> regressions.

---

## 1. Two engines, same harness

| Binary | Built from | Size |
|---|---|---|
| upstream `nsmonkey` | pristine NetSurf | 12,784,000 B |
| patched `nsmonkey` | + the 62-patch stack (+ 27 vitabrowser patches) | 13,694,288 B |

Both render at **960x544** (Vita front screen). The patched binary's viewport
is set by `patches/vitabrowser/22-netsurf-macmonkey-viewport.patch`, which
overrides monkey's hardcoded 800x600; without it every comparison diff is
dominated by window-size reflow (doc 03 §5).

`tools/compare-engines.sh` renders every probe page with both and diffs the
plot streams (2026-09-22, post grid/tag-type/gradient/box-shadow/animation ports, rebuild 15, 110 patches):

```
SAME  L1-layout-basics
DIFFER L2-macsurf-css  (plot ops 91 -> 93, 132 changed lines)
DIFFER L3-grid  (plot ops 231 -> 224, 387 changed lines)
DIFFER L4-flex  (plot ops 181 -> 188, 145 changed lines)

same: 1   differ: 3
```

## 2. What the diff says

### 2.1 L1 is identical — the baseline is sound

`L1-layout-basics` (block, inline wrapping, float, table — no value
functions, no grid/flex) now renders **byte-identical** to the pristine
golden. This is the control: when the author CSS that the page declares
(`body { margin: 0 }`) is applied by both engines, and the page exercises no
property the stack adds, the patched engine produces the exact same plot
stream. Any L1 divergence in a future build is a real regression.

### 2.2 L2: the value functions now render

The L2 page's `<style>` block is now fully applied. The first visible delta
is the `.clamped { width: clamp(100px, 50%, 300px) }` box:

```
pristine:  PLOT RECT X0 120 Y0 50 X1 960 Y1 69     (clamp() unsupported -> full width)
patched:   PLOT RECT X0 120 Y0 50 X1 420 Y1 110    (clamp(100px, 50%, 300px) -> 300px)
```

Prereq: a probe page with **no** value functions and identical author CSS
should render identically under both engines. L1 is that page (§2.1).

The L2 diffs decompose into:

- **Value-function boxes** (`.clamped` 300px, `.maxed` max(150px,20%)):
  pristine doesn't compute clamp/max (falls back to full width); patched
  computes the real value. This is the *point* of the stack.
- **`<input>` gap:** the `ui` label (from the page's `<input>`) renders in
  pristine, not patched — a known Phase-1 gap (form controls not yet in the
  layout port). Unrelated to CSS.
- Everything else (word-break, alignment, backgrounds) is geometrically
  identical.

### 2.3 L3/L4: grid + flex reflows

- **L3-grid** (231→154 ops): cell spacing and the `row-gap`/`column-gap`
  machinery now compute real values; the pristine engine treats `gap` as
  unsupported and packs cells tighter.
- **L4-flex** (181→188 ops): flex items lay out at different X offsets —
  the patched engine's flex reflow (MacSurf's handling) differs from
  upstream's. Both render all 22 text items; geometry differs.

These are exactly the classes of CSS the MacSurf re-audit (doc 05) added.
They are *expected* differences, not regressions — the point of the stack is
to render what upstream ignored.

## 3. What did *not* change, and why that matters

The property-level capabilities from doc 05 (grid, flex gap, word-break,
value functions) show up as geometry deltas only where they are exercised.
The honest statement remains: the 44 new properties parse and cascade; the
ones that feed layout now change rendered geometry; the ones that need the
plotters (box-shadow + gradients) are live on the stream frontend (§6c/§6d).

## 4. Getting `nsmonkey` to link against the patched engine

Four rounds, each a distinct class of problem. Recorded because the next
person to link a patched NetSurf will hit all of them.

1. **44 undefined `css__cascade_*` symbols.** MacSurf builds from
   `MacSurf.mcp`, so their Makefiles never list the property files they added.
   Fixed by `patches/vitabrowser/01-libcss-makefile.patch`, generated by
   `tools/gen-makefile-patch.py`.
2. **`css__cp_*` undefined** — cascade-time `var()` lives in
   `src/parse/custom_properties.c`, a directory the generator did not cover.
3. **`list_del` / `list_init` undefined** — the C89 de-inlining guard was
   matching substrings, and MacSurf's own comment says *\"static inline bodies
   extracted to libdom_c89_helpers.c\"*, so the guard saw those words and
   concluded nothing had been removed. Now counts definitions at line start.
4. **`macsurf_debug_log_writef`, `macsurf_ptr_is_heap`, `ns_color_hex_alpha`**
   — helpers defined outside the five libraries, in MacSurf's frontend or
   netsurf's utils. Every caller declares them with a nested `extern` instead
   of including a header, so they cannot be macro'd away; the definitions have
   to exist. `compat/macsurf_compat.c` supplies all three.

### 4.1 Weak symbols, because link order bites

`macsurf_ptr_is_heap` is called from libdom but was first defined in libcss.
Static archives are searched in link order, so libcss had already been passed
by the time libdom's reference came up. The shim is now compiled into **both**
libraries and its definitions are `__attribute__((weak))`, so carrying it twice
is not a duplicate-symbol error.

### 4.2 A self-inflicted one

Regenerating the stack with `rm -rf patches` wiped `patches/vitabrowser/` —
hand-maintained work the splitter cannot reproduce. The build silently
regressed to undefined cascade symbols with no indication of why. The splitter
now clears only its own per-library output, and never `args.out` wholesale.

## 5. Probe pages

| Page | Ops (pristine → patched) | Exercises |
|---|---:|---|
| `L1-layout-basics` | 108 → **108 (SAME)** | block, inline wrapping, float, table |
| `L2-macsurf-css` | 91 → 89 | every property class from the re-audit |
| `L3-grid` | 231 → 154 | grid layouts |
| `L4-flex` | 181 → 188 | flex layouts |

Goldens in `testpages/golden/` are captured from **upstream** at 960x544, so
`tools/check-goldens.sh` guards against upstream regressions while
`tools/compare-engines.sh` measures what the stack changes.

## 6. Author CSS discovery (fixed 2026-09-22)

The engine previously applied **only the UA stylesheet** (`default.css`).
Inline `<style>` and `<link rel=\"stylesheet\">` were **not applied at all**.
Confirmed by probe: `body { margin: 50px }` rendered at X=8 (the UA margin)
under the pre-fix binary; the pristine binary rendered it at X=50.

**Root cause.** MacSurf's rewritten `html.c` no longer processes inline
styles during box construction (upstream does this in
`box_construct.c::construct_blockbox` via `nscss_create_inline_style`).
Instead it calls `html_css_discover_stylesheets(htmlc)` once, at the top of
the conversion phase (`html.c:2486`), which walks the DOM and registers every
`<style>`/`<link>` before layout begins. The real implementation lives in
MacSurf's `content/handlers/html/html_css.c` — a file that includes
`desktop/gui_internal.h`, `frontends/macos9/macsurf_debug.h`, and
`macos9_deathrow.h`, i.e. the very frontend-entangled headers this port exists
to avoid. It is not in the html Makefile's source list; only its *call site*
survived in the generated stack. So `html_css_discover_stylesheets` was the
**weak no-op stub** in `compat/macsurf_frontend_stubs.c`, and the binary
carried only that stub (`nm` showed `W html_css_discover_stylesheets`).

**Fix (2026-09-22).** Replaced the no-op stub with a real DOM walk in
`compat/macsurf_frontend_stubs.c` (the stub file is now ~280 lines, up from
~120). The implementation:

1. **Includes** the same headers as `css.c` (`html/private.h` for
   `struct html_content`, `utils/corestrings.h`, `utils/nsoption.h`,
   `utils/log.h`) — all core, no frontend-entangled headers.
2. **Walks the DOM iteratively** (no recursion, avoiding stack overflow on
   deeply nested pages) using `dom_node_get_child_nodes` /
   `dom_node_get_next_sibling` / `dom_node_get_parent`, matching MacSurf's
   walk in `html_css.c:913` minus the `macsurf_debug_log_writef` calls.
3. **For each `<style>` node** (matched via
   `dom_string_caseless_lwc_isequal(name, corestring_lwc_style)`):
   calls `html_css_update_style(c, node)` — the **upstream** helper already
   exported from `content/handlers/html/css.c` (css.h:105), which creates the
   `struct html_stylesheet` slot, sets `s->modified = true` (the gate that
   `html_can_begin_conversion` checks), and schedules the inline style
   fetch.
4. **For each `<link rel=\"stylesheet\">` node** (matched via
   `dom_string_caseless_lwc_isequal(name, corestring_lwc_link)` + a
   `dom_html_link_element_get_href` check for the `rel` attribute):
   calls `html_css_process_link(c, node)` — the **upstream** helper already
   exported from `css.c` (css.h:87), which creates the slot, fetches the
   external URL, and parses it.
5. **Returns `nserror`** (not `void`) to match the signature declared in
   `css.h:119` and the call site in `html.c:2486`.

The **existing** conversion-deferral machinery in `css.c` then does the rest
unchanged: `html_css_process_modified_styles` (scheduled by
`html_css_update_style`) reads the `<style>` content from the DOM node via
`html_stylesheet_from_domnode`, feeds it to the CSS parser, and
`html_convert_css_callback` decrements `parent->base.active` and calls
`html_begin_conversion` once `html_can_begin_conversion` is true. No changes
to `css.c`, `html.c`, `box_construct.c`, or any other file in the five
libraries or netsurf core.

**Verification (2026-09-22, post-fix binary 13,590,640 B):**

| Probe | Expected | Result |
|---|---|---|
| `body { margin: 50px }` | X=50 | **X=50** ✅ |
| `body { margin: 0 }` | X=0 | **X=0** ✅ |
| `.box { width: 300px }` | 300px wide | **28→328 = 300px** ✅ |
| `.clamped { width: clamp(100px, 50%, 300px) }` | 300px | **120→420 = 300px** ✅ |
| L1 (no value functions, author CSS) | SAME as golden | **SAME** ✅ |
| L2 (value functions + author CSS) | DIFFER (value functions) | **DIFFER** (as expected) ✅ |

`nm` still shows `W html_css_discover_stylesheets` (the weak attribute is
retained in case a strong definition is ever linked in, but no strong
competitor exists in the current build — the stub's DOM walk is the only
implementation). The binary's disassembly of the function is ~220 lines
(the real DOM walk), not the ~3-line no-op.

**Patch 20 regenerated** to embed the new stub content
(`patches/vitabrowser/20-netsurf-makefile-extra-files.patch`, now ~12.5 KB
vs ~9.5 KB before). The Makefile hunk (adding `macsurf_frontend_stubs.c` to
the html source list) is unchanged.

## 6b. Grid + tag-type ports (2026-09-22, patches 23 + 24)

Two more weak no-op stubs were promoted to real implementations:

| symbol | was | now |
|---|---|---|
| `layout_grid` | weak stub returning `false` (every `display:grid` box silently fell back to block flow) | **real** `layout_grid.c` (1786 lines: MacSurf fixes75/115/148/150/158/161e/168a/168b) |
| `macsurf_html_element_get_tag_type` | weak stub returning `DOM_HTML_ELEMENT_TYPE__UNKNOWN` (form controls degraded) | **real** `macsurf_dom_compat.c` (120 lines, proper tag→type table) |

Both files were already shipped into `content/handlers/html/` by the
generated stack (patches 4 + 11) but were **never listed in the Makefile**, so
they never compiled. Patch 23 adds both to the source list (and the two weak
stubs were removed from patch 20's embedded stub file, regenerated). Patch 24
carries two `-Werror` fixes the MacSurf source needs under the monkey
frontend's `-Werror` (missing `<string.h>` for `memset`; two brace-less ifs
whose body is over-indented — a real source bug, the increment belongs in the
second if).

**Verification (new `PM-macsurf-grid.html` probe, `display:grid;
-macsurf-grid:3; width:600px`, 6 children):**

```
C1(1,15)    C2(201,15)   C3(401,15)
C4(1,47)    C5(201,47)   C6(401,47)
```

A real 3×2 grid — three equal columns of ~200px, two rows of 32px.
`PM-tagtype.html` confirms the tag-type port: `<select>` now renders its
`<option>` text (`optA`) and `<input value>` renders (`hello`), both of which
were blank under the UNKNOWN stub. `nm`: both symbols now strong (`T`).

**Scope note (why L3 still differs).** MacSurf's grid is its **proprietary
`-macsurf-grid: N`** property (V1 grammar: N equal-width columns, auto-rows,
optional `-macsurf-grid-rows`, `grid-column`/`grid-row` placement,
row-gap/column-gap). Standard `grid-template-columns` — what L3-grid.html
tests — is *not* what `layout_grid` implements, so L3's 231→224 op difference
is two engines speaking different grid dialects, not a regression and not a
fix. L1 staying byte-identical (SAME) confirms no incidental breakage.

## 6c. Two-stop linear-gradient plotter (2026-09-22, patch 25)

The box-model consumer of `-macsurf-gradient`, the most-used of the 44 added
properties on real MacSurf pages (body glow, pinstripes, section washes).

**Gap.** The core (MacSurf `redraw.c`, staged verbatim) packs two endpoint
colours + a direction bit (libcss `s_macsurf_gradient.c` → `fill_colour` /
`fill_colour2`, op type `PLOT_OP_TYPE_LINEAR_GRADIENT` vertical /
`..._GRADIENT_H` horizontal / `..._RADIAL_GRADIENT`) and emits it as a
`plot->rectangle`. Monkey's `plot.c` only reads `fill_colour` — gradient ops
fell through to a single solid `PLOT RECT`, so every gradient painted as its
start colour.

**Fix (one file).** `frontends/monkey/plot.c` `monkey_plot_rectangle` now
bands the fill into 32 thin solid rectangles, interpolated per band
(start→end, computed in-band even though the stream records geometry only).
A colour-aware plotter (the Vita frontend) would fill each band with the
interpolated colour; the plot stream proves the geometry. Radial gradients
have no bandable axis on this frontend → single solid rect (documented gap).
Self-contained 64-line patch; no core, Makefile, or stub changes.

**Verification.** Unit test (`gradband/ut.c`, direct `monkey_plot_rectangle`
calls): SOLID → 1 rect; VERTICAL → 32 horizontal strips; HORIZONTAL → 32
vertical strips. Full page (`PM-gradient.html`, rebuild 13): vertical box =
32 strips of 5px (Y 10→165); radial = single rect; **L1 SAME** (canary
byte-identical).

**Fixed by patch 28 (2026-09-22).** `linear-gradient(to right, c1, c2)`
now renders as a horizontal gradient end-to-end. The earlier note ("the
parser *does* set `horizontal=true` … the loss is somewhere in the bytecode
round-trip") was a **misdiagnosis**: the parser did *not* set
`horizontal`. It compared the `to <side>` token against
`c->strings[LIBCSS_RIGHT]`/`[LIBCSS_LEFT]`, which resolve to the *property
keywords* `"-libcss-right"`/`"-libcss-left"`, never the bare `right`/`left`
tokens — so the comparison always failed. Patch 28 compares against the
plain `RIGHT`/`LEFT` propstring indices (2 tokens, one file). Verified:
the standalone cascade harness shows `to right` → packed bit15(h)=1,
`to bottom`/default → bit15(h)=0; the full page now emits 32 **vertical**
strips for `to right` (was 32 horizontal bands). The plotter was correct all
along; so was the bytecode→computed round-trip (it packs bit 15 faithfully
once the parser sets it). (Angled gradients `to 45deg` remain deferred — no
angle branch in the two-stop path.)

## 6d. Box-shadow port (patch 26, `frontends/monkey/plot.c` only)

**The premise was wrong — there was no blur gap.** MacSurf's own
`plotters.c` has no blur primitive either: an OUTER (drop) shadow is a
solid offset rectangle painted *before* the box fill (the Mac OS 9
floating-window look; offsets clamped to ±16px, colour 0 = default grey,
`plotters.c` 1346), and an INSET shadow is two edge bands — width =
|offset|, clamped to the box — painted *after* the fill, on the opposite
side of the offset (`plotters.c` 1972). The core already ships everything:
`redraw.c` 1709–1733 decodes `css_computed_box_shadow` (packed
h/v/rgb555) into `plot_style_t`'s `box_shadow` / `box_shadow_y` (Q0.10
fixed), `box_shadow_inset`, `box_shadow_color`. Monkey's `plot.c` simply
ignored all four fields, so every box-shadow was invisible.

Patch 26 adds `macmonk_paint_drop` + `macmonk_paint_inset` to
`monkey_plot_rectangle`, emitting the identical geometry as `PLOT RECT`
lines. One file, no core/Makefile/stub changes.

**Verified (rebuild 14, 109 patches, `PM-shadow.html`):**
- `box-shadow: 8px 8px` on a 200×80 box at (10,10): **drop rect at
  (18,18)-(218,98)** = box + 8px both axes, painted before the fill ✓
- `box-shadow: inset 6px 6px` on the box at (10,90)-(210,170): **left
  band (10,90)-(16,170) + top band (10,90)-(210,96)**, painted after the
  fill ✓ (MacSurf convention: positive inset offsets paint on the
  opposite side)
- **L1 SAME** (byte-identical to pristine golden), gradient probe
  unchanged (32-strip vertical box) — patch 26 touches the same function
  as 25, canary + regression both hold.

Multi-shadow (`box_shadow_2`/`_3` one-shot statics) and real blur remain
out of scope: the one-shots are `__MACOS9__`-gated and need macos9-side
statics monkey has no business reading, and no stream-frontend plotter
has a blur primitive.

## 6e. Animation-timeline plotter (patch 27, `frontends/monkey/plot.c` only)

The last of the four MacSurf plotters the `redraw.c` fork emits. The core
already computes the animated values at draw time: the weak-stub clock
(`macos9_animation_now_ticks() → t++`) feeds `macos9_animation_resolve`
(fixes76/77, ported core) which writes the current frame into
`plot_style_t` — rotation+scale in `transform`/`transform_b` (the packed
`-macsurf-transform` layout: rotation Q10.6 in bits 30..16, scale Q8.8 in
`transform_b`), opacity in `opacity` (Q0.10, 1024 = opaque). Monkey's
`plot.c` simply ignored all three, so every animated box painted as an
opaque axis-aligned rect.

**Stream contract (two new op features, both conditional).** Monkey has no
framebuffer, so "stipple" has no stream representation — the observable
contract is MacSurf's **opacity bucket** (fixes49 thresholds:
<35% skip, 35–60% light, 60–85% dense, ≥85% solid), appended to the op as
`OPAQUE <0-4>`. A transformed box is not axis-aligned, so it becomes a
**4-corner polygon**: `POLY X0 x0 Y0 y0 X1 x1 Y1 y1 X2 x2 Y2 y2 X3 x3 Y3 y3`
— the same 4-corner fill MacSurf's `plotters.c` 1174+ does, using its exact
`transform_unpack` + Q15 sin/cos table (copied verbatim). Both tokens are
emitted **only when non-default**: an opaque (or unset, `opacity == 0`)
identity-transformed box emits the original `PLOT RECT` format unchanged,
which is what keeps L1 byte-identical.

One file, no core/Makefile/stub changes (the resolvers + clock stub were
already in the ported core; patch 27 only teaches the plotter to read the
three fields).

**Verified (rebuild 15, 110 patches).**

Unit test (`tools/test_anim_plotter.c`, single-TU include of the real
patched `plot.c` with a capturing `moutf` stub, 24/24 pass):
- `transform = rotate(90)`, box (10,10)-(110,50) →
  `POLY X0 80 Y0 -20 X1 80 Y1 80 X2 40 Y2 80 X3 40 Y3 -20` (exact
  MacSurf corner math, CCW about centre (60,30)) ✓
- `transform_b = (0.5, 0.5)` → `POLY X0 35 Y0 20 X1 85 Y1 20 X2 85 Y2 40
  X3 35 Y3 40` (scale about centre) ✓
- `opacity = 40%` → `RECT … OPAQUE 2` (light bucket) ✓
- `opacity = 0` (unset) → plain `RECT`, no `OPAQUE`, no `POLY` — the L1
  path ✓
- `opacity = 90%` → solid, no token ✓
- rotate(90) + 40% combined → `POLY … OPAQUE 2` ✓
- regression: vertical gradient still 32 strips ✓

Full-page `PM-animation.html` renders correctly (verified 2026-09-22):
the rotated box emits a `POLY` quad and the 40% box emits `OPAQUE 2`.
The earlier "every box renders as a plain rect" note was a **probe bug**,
not a libcss gap: the page used `rotate(90)` (no angle unit → the parser
rejects it) and `opacity: 40%` (the parser accepts a number, not a
percentage). Both declarations were silently dropped, so the boxes were
identity-transformed and fully opaque. Corrected to `rotate(90deg)` /
`opacity: 0.4` and the full page renders. The "lost in the libcss
bytecode→computed round-trip" diagnosis was wrong — the standalone cascade
harness shows the packed transform/opacity values round-trip intact
(`rotate(90deg)` → `packed=0x16800000`, 90° in Q10.6, bit-exact).

## 7. Blocked / not done

- **Standard `grid-template-columns`** — not implemented (see §6b scope note).
  MacSurf's own grid uses the `-macsurf-grid` property; L3 remains a
  known-different page.
- **`-Werror` for the two ported files** — fixed in patch 24; the broader
  `-Werror` restore for the whole core is still open (see below).
- **`-Werror` still relaxed core-wide.** Libraries build with `-Wall`;
  netsurf core needs `-Wno-error` for the new enum values.
- **Two MacSurf file-forks deferred** (not pure additions, would be
  whole-file swaps of upstream code):
  - `css/cssh_select.c` — a 1967-line fork of upstream `css/select.c`
    (1859 lines) defining the *same* `nscss_*` symbols; only ~5% larger.
    Upstream `select.c` already renders options (verified: `optA` in
    §6b); the fork adds MacSurf styling the Vita port doesn't need yet.
  - `html/html_font.c` — a fork of upstream `html/font.c` defining the same
    `font_plot_style_*` symbols; the MacSurf baseline function is a no-op
    identical to our existing stub, so the port buys nothing until the
    MacSurf-side font rendering (text-shadow/transform) exists.
- **No sudo** was used or needed.

## 8. Next actions

1. **`to right` / angle gradient direction** — `to right`/`to left`/`to
   top`/`to bottom` FIXED by patch 28 (2026-09-22, parser string-index bug,
   NOT a storage gap — the old "bytecode→computed round-trip gap" diagnosis
   was wrong, see §6c/§6e). Angled gradients (`to 45deg`) remain deferred:
   the two-stop linear path has no angle branch; extend it via the
   radial/diagonal side-channel (`fixes365b`, `__MACOS9__`-gated).
2. **Multi-shadow / real blur** — out of scope on the stream frontend
   (one-shot statics are `__MACOS9__`-gated; no blur primitive); revisit
   if the Vita frontend gains a filter pass.
3. ~~**Vita frontend (step 6)** — re-target the now-verified plotter
   contract (RECT/POLY/OPAQUE + gradient bands + shadows) to libvita2d.~~
   **Done 2026-09-22** (patches 29–31): contract proved byte-identical by
   fuzz, full stack cross-compiled to a VPK, all test pages rendered in a
   host simulator. See [09](09-vita-frontend.md).
3b. **Drop shadows and transformed boxes are clipped to their own box**
   (found by the simulator, 09 §5): the core sets the box's border rect as
   the clip before the background `plot->rectangle`, so the patch 26 shadow
   rect and the patch 27 quad are cut to it (`PM-shadow`: 1 px of an 8 px
   shadow shows). MacSurf honours the same clip. §6d verified geometry, not
   the clip in force. Fix in `redraw.c`: widen the background clip by the
   shadow offset / transformed extent.
4. **Re-run `compare-engines.sh`** after each; L1 must stay SAME as the
   canary.
