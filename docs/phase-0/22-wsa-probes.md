# WS-A Rendering Probes — Firefox Baselines (2026-10-19)

Probed against Firefox via Camoufox. VitaBrowser status from code inspection.

## (a) opacity on inline boxes

**Firefox:** `<span style="opacity:0.5">` → computed opacity 0.5, paints at 50%.
`<span style="opacity:0.3">` → computed 0.3, paints at 30%. Block control
paints correctly.

**VitaBrowser:** `html_redraw_box` (redraw.c:4844) composes group opacity for
all boxes including inlines, and skips opacity:0 subtrees. BUT per the code
comment (redraw.c:4634): "Text, borders and images at partial opacity still
paint opaque." So `<span style="opacity:0.5">text</span>` paints its text at
100%. **GAP** — partial opacity on text/borders/images not implemented.

## (b) light-dark() / color-scheme

**Firefox:** `light-dark(black, white)` resolves to black in light scheme,
white when `color-scheme: dark` forces dark. `color-scheme: dark` on element
forces dark values.

**VitaBrowser:** libcss has `prefers_color_scheme` (for `@media`), but:
- No `light-dark()` function in libcss.
- No `color-scheme` property in libcss.
**GAP** — both unimplemented.

## (c) SVG `<use>`

**Firefox:** `<use href="#myc" x="60">` renders the referenced circle shifted
by x=60. No shadow DOM exposed (`shadowRoot` null, no children). `getBBox()`
returns the shifted bbox (70,10,40,40 for circle at 30,30 r=20 with x=60).
`getComputedStyle(use).fill` returns default (not inherited from referenced).

**VitaBrowser:** No inline SVG support. SVG is handled only as `<img>` via
rsvg/libsvgtiny (image.c). `<svg>` elements in HTML and `<use>` are not
implemented. **GAP**.
