# Bitmap opacity channel (design, 2026-10-20): carrying group opacity to the bitmap plot op

Design only — no implementation in this document's commit. This is
the design pass patch 314's header called for ("closing images
needs an op-channel design first, like item 7 needed doc 19").
Background fills compose group opacity (patch 149), text composes
it (patch 311), borders compose it (patch 314) — all by folding
the composed value into a colour's alpha before the plot op runs.
An image has no colour to fold into: what it needs is a channel
from the painting box to the bitmap plot op, and no such channel
exists. This document designs one, states what each image call
site must do to feed it, and keeps separate — as patch 314's
caveat kept separate — what the simulator can verify from what
only a device can.

## Constraints (from the record, not negotiable in the design)

1. **The plotter table is a shared contract; queued ops replay
   from what they store.** `ns_plotter_table` (include/netsurf/
   plotters.h) is implemented per frontend, and desktop knockout
   compositing (desktop/knockout.c) queues plot ops and replays
   them later from the queued entry. A bitmap entry stores its
   `flags` verbatim and the replay passes them unchanged
   (`knockout_plot_bitmap_recursive` → `real_plot.bitmap(...,
   entry->data.bitmap.flags)`) — so a channel encoded in the op's
   own arguments survives knockout; a channel held in frontend
   state, or keyed on call order, is not in the entry and cannot
   be replayed. The channel must ride in the op.
2. **Trace discipline (patches 311/314).** An op that draws
   non-solid appends ` OPAQUE <bucket>` to its trace; solid draws
   trace exactly as before, so solid pages' plot dumps stay
   byte-identical and the gate's existing counts are undisturbed.
   BITMAP traces and the replay path follow the same rule.
3. **One quantisation site.** The vita plotter quantises alpha to
   buckets — `vita_bucket_alpha[]` = {0, 64, 128, 191, 255} in
   frontends/vita/plot.c — and `vita_plot_rgba(c, bucket)`
   substitutes the bucket alpha for a colour's. Ops that receive a
   plot style derive their bucket via `vita_geom_opacity_bucket`.
   The bitmap channel should carry enough resolution for the
   plotter to quantise the same way (a full byte), not force
   every call site to quantise on its own.
4. **The stub is the device contract.** The frontend compiles
   against the vita2d entries declared in tools/vita-stub/vita2d.h;
   there is no vitaSDK on the build VM, so any entry beyond the
   stub is an assumption about the device library that only a
   toolchain or hardware run can settle. A stage may only *ship*
   code whose device side rests on stub-declared entries, or must
   be explicitly gated on the device check that settles it.

## Where image painting is today (census of the call sites)

- **The op.** `bitmap(ctx, bitmap, x, y, width, height, bg,
  flags)`; `bitmap_flags_t` spends bit 0–1 on repeat
  (BITMAPF_REPEAT_X/Y), bit 2 on BITMAPF_NEAREST, and bits 8–12
  on the blend mode (BITMAPF_BLEND_MASK / BITMAPF_BLEND_MODE(m)).
  No consumer in the tree reads any other bit.
- **The four image content handlers** — content/handlers/image/
  bmp.c, image.c, nssprite.c, rsvg.c — each implement their
  content's redraw by building flags from their
  `content_redraw_data` (`data->repeat_x/y`, and
  `BITMAPF_BLEND_MODE(data->background_blend_mode)`) and calling
  `ctx->plot->bitmap`. They receive the content, the redraw data
  and the context — never the painting box, and nothing in
  `content_redraw_data` today carries a per-box paint scalar
  except `background_colour` and `background_blend_mode`.
- **The background-image call site** (content/handlers/html/
  redraw.c, the `ctx->plot->bitmap` call in the background
  painting path) builds its flags in the same file that owns the
  composed group opacity: `g_group_opacity`, exported since patch
  314 as `html_redraw_group_opacity()`. Nothing folds it in.
- **The carrier precedent.** `background_blend_mode` is the
  template for how a per-box scalar legally reaches a handler:
  redraw.c computes it from the box's computed style and stores
  it in the redraw data at each fill site (redraw.c: the
  background data and the image-box data), and each handler folds
  it into the op flags at its call. A group-opacity carrier
  follows exactly this shape.
- **The vita end.** `vita_plot_bitmap` (frontends/vita/plot.c)
  draws each tile with `vita2d_draw_texture_scale` — an entry
  with no colour or tint parameter. The stub does declare
  `vita2d_draw_texture_tint_part` (a texture part drawn at 1:1
  with a tint colour), and the simulator implements it as
  texel × tint modulation (tools/vita-sim/vitasim.c) — the same
  mechanism frontends/vita/text.c's glyph atlas already draws
  through, which is how patch 311's text fading reaches pixels.
  No entry that both *scales* and *tints* is declared in the
  stub, and the simulator implements none.
- **The same class, recorded at 314:** `vita_plot_disc` passes
  VITA_BUCKET_SOLID explicitly for its fill circle and strokes
  via the solid `stroke_polyline` wrapper; `vita_plot_arc`
  strokes the same way; `vita_plot_path`'s filler
  (frontends/vita/pathfill) ignores the style's bucket. Unlike
  bitmaps, all three ops *receive* a `plot_style_t`, from which
  `vita_geom_opacity_bucket` already derives the bucket for the
  line, rectangle and polygon ops.

## Shape — where the channel attaches

Three candidate shapes, assessed against constraint 1:

- **(a) A byte in the op flags (recommended).** Define
  `BITMAPF_OPACITY_SHIFT 16`, `BITMAPF_OPACITY_MASK (0xff << 16)`
  and `BITMAPF_OPACITY(a)` in include/netsurf/plotters.h,
  alongside the blend-mode encoding it mirrors. The composed
  opacity byte travels with the op, survives knockout verbatim
  (constraint 1), and needs no signature change anywhere. The
  encoding's zero rule is what makes it safe to add: a masked
  value of 0 means *no opacity supplied* and the plotter draws
  opaque — which is what every existing caller in the tree
  produces today, since none of them writes the field. Folding
  call sites write `max(composed_byte, 1)`: a composed opacity
  of exactly 0 therefore lands on byte 1, which the plotter's
  existing byte→bucket quantisation (the one colour alpha
  already goes through) puts in bucket 0 — draw skipped, as
  opacity 0 requires. One code point (a literal byte of 0) is
  spent on backwards compatibility; every other value means
  what it says.
  Frontends that do not know the bits ignore them — the same
  position blend mode is in today.
- **(b) A `content_redraw_data` field as the whole channel.**
  Sufficient for the four handlers (they are the callers), but
  the background-image site does not go through a handler, every
  future caller re-implements the fold, and knockout entries —
  which store flags, not redraw data — lose it. Rejected as the
  channel; retained as the *carrier* that feeds (a) at the
  handler calls (stage 2).
- **(c) Plotter state (a set-opacity call or side table).**
  Rejected: not stored in knockout entries (constraint 1),
  ordering-fragile under interleaved ops, and its failure mode is
  the worst of the three — a leaked state paints a later,
  unrelated image faded instead of one image solid.

**Per-handler changes (stage 2).** A new `content_redraw_data`
field — `opacity`, a byte — filled by redraw.c at the same sites
that fill `background_blend_mode` for image boxes, from
`html_redraw_group_opacity()` quantised to a byte. Each of the
four handlers adds one fold beside its blend fold:
`flags |= BITMAPF_OPACITY(data->opacity)`. The background-image
site (stage 1) folds `html_redraw_group_opacity()` directly — it
is already in the file that owns the value, so it needs no
carrier. Every other `content_redraw` caller (a standalone image
document painted through the browser window, history/treeview
thumbnails via desktop code) must leave the field at its
zero/solid default: the patch that adds the field enumerates the
fill sites and states the default rule in its header, and the
gate carries a standalone-image leg to prove no regression
there.

**The disc/arc/path class needs no channel.** Each op already
receives its plot style; the fix is per-op adoption of
`vita_geom_opacity_bucket(style)` exactly as patch 314 did for
line/polygon/rectangle: disc's fill circle and stroke, arc's
stroke (via `stroke_polyline_bucket`), the path filler's fill
and stroke — with trace suffixes under constraint 2. It rides
stage 1 as a companion because it shares the gate page, not
because it shares the mechanism.

## The vita2d end — what is sim-verifiable, what is not

At bucket SOLID the bitmap path must remain byte-identical to
today: `vita2d_draw_texture_scale`, no suffix in the trace. For a
non-solid op the plotter has to modulate texel alpha by the
bucket, and the honest inventory of ways to do that is:

- **Unscaled tiles (1:1): sim-verifiable now.**
  `vita2d_draw_texture_tint_part` with a white tint at the bucket
  alpha does it, in the simulator by construction (texel × tint,
  the text mechanism) and on device by libvita2d's documented
  tint semantics for that entry — and the entry is in the stub,
  so constraint 4 is satisfied. Tiled backgrounds at 1:1 — the
  common background-image shape — are in this class.
- **Scaled tiles: no stub entry both scales and tints.**
  Two ways forward, and the choice between them is the design's
  one real fork:
  - *CPU pre-multiply (device-safe).* Copy the texture, scale
    its alpha bytes by the bucket once, draw the copy with
    `vita2d_draw_texture_scale`. Uses only today's stub entries,
    so it ships without any device assumption; the simulator
    verifies the pixels exactly. Its cost is one texture copy
    per faded scaled image per redraw — bounded (paid only when
    the bucket is non-solid) and cacheable against the source
    bitmap, but real CPU on the device for large photos.
  - *A scale-tint stub entry (device-dependent).* Declare a
    `vita2d_draw_texture_scale_tint`-shaped entry in the stub,
    implement it in the simulator, and call it. If the device
    libvita2d has the corresponding entry with the expected
    modulation semantics, this is free on the GPU; if it does
    not, the device build fails at link time — a fact this VM
    cannot settle (constraint 4). This path may only ship gated
    on a vitaSDK or hardware check.
  The design recommends pre-multiply for the first shippable
  patch (it also gives the gate an exact pixel oracle for scaled
  images), with the scale-tint entry as a later, device-verified
  optimisation that swaps the plotter's scaled path only.
- **Replay/png checks** read the trace suffix and the snapshot
  pixels exactly as patches 311/314 established; nothing about
  the verification method is device-dependent.

## Staged surface

- **Stage 1 — channel definition + background images + the
  disc/arc/path class.** The flags byte in plotters.h; the vita
  plotter extracts it, traces `OPAQUE <bucket>` when non-solid,
  and implements both draw paths above (tint-part at 1:1,
  pre-multiply when scaled); redraw.c's background-image site
  folds the accessor; disc/arc/path adopt their style buckets.
  No handler changes. Gate legs: background-image (tiled and
  scaled) and the disc/arc/path shapes.
- **Stage 2 — the four image handlers.** The `content_redraw_data`
  carrier + redraw.c fill sites + one flags fold per handler.
  Gate gains `<img>` legs per format family the simulator can
  decode (png through image.c at minimum; bmp, nssprite and
  rsvg legs as fixtures allow), plus the standalone-image
  invariant leg.
- **Stage 3 — device-verified scale-tint (only if wanted).**
  Replace the pre-multiply path with the stub scale-tint entry
  once a vitaSDK build or hardware run confirms the entry
  exists with the expected semantics. Not schedulable from this
  VM; recorded so stage 1's pre-multiply is understood as the
  safe default, not the final word.

## Failure semantics

- A handler or call site that misses its fold paints its image
  solid — visible, and countable per format by the gate's legs;
  never a crash, never a wrong-alpha blend. The missed-fold
  failure class is exactly what the per-format gate legs exist
  to catch.
- An opacity byte of bucket 0 (group opacity 0) skips the draw
  entirely, as fills and text already vanish at opacity 0 — an
  `opacity: 0` subtree must not leak its images.
- Unknown flag bits are ignored by frontends that do not know
  them (the blend-mode position today); the vita plotter masks
  only its defined bits.
- The pre-multiply scratch texture is bounded by the largest
  faded scaled image on the page and freed with the redraw; a
  failed allocation falls back to drawing solid (counted as a
  decline in the frontend's diag, never a partial blend).

## Gate page (spec)

Extend the CSS-opacity page family with
`testpages/pages/CSS-opacity-image.html`, prefix OPIMG, using the
311/314 pixel method (opaque test colours, exact bucket pixels):

1. **Background image, tiled 1:1**, inside `opacity:.5`: BITMAP
   trace carries `OPAQUE 2`; snapshot pixels read the texel
   colour blended at bucket alpha (the 127-class reading the
   suite already uses); the solid control's trace is
   byte-identical to today's (no suffix).
2. **Repeat composition:** the same leg with repeat in both axes
   — every tile faded; the flags byte must compose with the
   REPEAT bits, not clobber them (and the blend bits, where a
   blend mode is also set).
3. **Scaled background / `<img>`** (stage 2 for the `<img>` leg):
   width ≠ intrinsic at partial opacity → faded via the scaled
   path, pixel-checked at a texel-centre sample.
4. **`<img>` per format** (stage 2): one leg per handler family
   with an available fixture, same trace + pixel expectations.
5. **Disc/arc/path legs:** a disc (list marker / radio shape), an
   arc and a canvas-style path inside `opacity:.5` read at
   bucket alpha, with DISC/ARC/PATH trace suffixes per the
   311/314 discipline.
6. **Opacity 0:** an image inside `opacity:0` paints nothing.
7. **Suite invariants:** the CSS-opacity (311) and
   CSS-opacity-group (314) counts unchanged; a standalone image
   document paints solid; interaction 52/52; solid pages' plot
   dumps byte-identical across the suite.

## Cost expectation

The channel itself is one flags fold and one bucket lookup per
bitmap op — noise. The tint-part path costs nothing extra in the
simulator's terms that matters and is GPU-side on device. The
pre-multiply path is the only real cost in the design: one
width×height alpha pass per faded scaled image per redraw, paid
only when a page actually puts a scaled image inside a group
below full opacity — pages without group opacity pay nothing
and dump byte-identical traces. On the host that pass is
measurable on the gate page's largest image before the stage
ships (the project's rule: no host win-or-neutral measurement,
no ship); on the device factor it is the deliberate price of not
depending on an unverified library entry, and stage 3 exists to
retire it if the device check ever confirms the tint entry.

## Open questions

1. **The scaled-path fork.** Pre-multiply first (device-safe,
   CPU per redraw), or hold the scaled leg until a vitaSDK /
   hardware check settles whether a scale-tint entry exists?
   This design recommends pre-multiply first so stage 1/2 can
   ship and be device-verified as they stand — but it spends
   device CPU on exactly the large-photo case the Vita is worst
   at, so the trade is the owner's to confirm.
2. **Byte vs bucket in the flags word.** The design spends eight
   of the flags word's free bits on a full opacity byte (one
   quantisation site, constraint 3). Three bits would carry the
   bucket directly but would put quantisation policy at every
   call site and cap any future frontend at this plotter's
   bucket table. Within this repo the byte is recommended; if a
   second frontend is ever targeted at the same table, the
   choice is worth revisiting in the open rather than inside a
   patch.
