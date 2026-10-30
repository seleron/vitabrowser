## Patch 346 (2026-10-30): libsvgtiny staged; relative t / q fixed at source

Patches 343-344 exposed two path bugs in libsvgtiny and papered over them
in the inline-SVG serializer (344 re-emitted every relative `t` and `q`
absolute, tracking the current point through the path):

- a relative `q` stored its control point in `quad_x/quad_y` BEFORE the
  relative offset, so the stored point was the raw relative operand, not
  the absolute control point. The next smooth curve reflected THAT, so
  even an absolute `T` after a relative `q` reflected wrongly (`M0
  24q24 -24 48 0T96 24` reached y 56 in a 48-unit box).
- `t`'s reflected control point is `prev + (prev - quad)`, already
  absolute, and the relative branch added `prev` to it again. Every
  relative `t` after a curve overshot (`M2 12q5 -10 10 0t10 0` reached
  (28, 34.7); the absolute-T equivalent stays within (22, 18.7)).

Both are now fixed in libsvgtiny itself (346): the control point is
stored after the offset, and `t` no longer re-offsets the reflection.
libsvgtiny is a support library, so staging it meant: build-patched.sh
copies the pristine tree into applytest/upstream (pristine check too),
both support builds pick up the patched copy (the host build in
build-patched.sh, the Vita cross build in build-vita.sh, which already
reuses $UP for the engine libs), and apply-patches.sh routes
NN-libsvgtiny-* names. 436 patches apply to the clean stack (435 +
346, only the two known collisions fail).

Standalone (libsvgtiny against the engine prefix): the wave `M0
24q24 -24 48 0t48 0V48H0Z` now emits the dip's reflected control at
(72, 48) -- the hump's (24, 0) mirrored about (48, 24) -- dip bottom
(72, 36); the buggy build emitted (120, 96). `q24 -24 48 0T96 24`
reflects the same.

Gate: CSS-svg-reltq -- the same wave as CSS-svg-smooth-quad, as a
standalone SVG through `<img>`, the path that never went through 344's
serializer: inside the dip (72,72) red, above it (72,46) the #eee
background, inside the hump (24,50) red, >=1 PLOT PATH, none OPAQUE.
With the bug (72,72) reads background. Chromium-verified.

Full gate: `gate346.log`, exit 0.

Scorecard google 54.8 -> 54.8 (identical to the r62-era run; the home
page has no `<img>` SVGs and no relative q/t, so no 346 code path runs
there -- the pixel diff vs the 18-day-old reference is trending-search
drift).
