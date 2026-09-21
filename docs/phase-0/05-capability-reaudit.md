# Phase 0 — re-audit of the §6 capability matrix

**Date:** 2026-09-21
**Method:** the brief's §6 claims checked against the 61-patch stack and the
MacSurf/upstream libcss trees, not against MacSurf's documentation.

> **Headline:** §6 was written from MacSurf's published status pages and is
> stale in both directions. **MacSurf's libcss adds 44 CSS properties upstream
> does not have**, including the CSS transitions §6 lists as unsupported and
> the `transform` that §9's Phase 2 queue lists as an open gap.

---

## 1. Properties MacSurf adds that upstream libcss lacks

Counted by taking every `src/select/properties/s_*.c` in MacSurf with no
upstream counterpart: **44 properties**.

| Area | Properties |
|---|---|
| **Transitions** | `transition-property`, `transition-duration`, `transition-delay`, `transition-timing-function` |
| **Animation** | `macsurf-animation-opacity`, `macsurf-animation-rotate` |
| **Transform** | `macsurf-transform` |
| Grid / alignment | `macsurf-grid`, `macsurf-grid-rows`, `macsurf-grid-flow`, `macsurf-grid-col-span`, `justify-items`, `justify-self` |
| Backgrounds | `background-size`, `background-origin`, `background-clip`, `background-blend-mode`, `macsurf-gradient`, `macsurf-hstripe-bg`, `macsurf-dotgrid` |
| Box | `border-radius`, `box-shadow`, `box-decoration-break`, `aspect-ratio` |
| Text | `text-decoration-color`, `-style`, `-thickness`, `text-align-last`, `text-justify`, `text-overflow`, `word-break`, `overflow-wrap`, `hyphens`, `hanging-punctuation`, `tab-size`, `macsurf-text-shadow` |
| Replaced content | `object-fit`, `macsurf-object-position`, `image-rendering` |
| Forms / UI | `appearance`, `accent-color`, `caret-color`, `pointer-events` |
| Other | `fill`, `row-gap` |

Only 12 of these carry the `macsurf_` name; the brief's §3.1 count of "24 new
files" was counting those 12 × (parse + select) and missed the other 32
entirely.

### 1.1 New CSS value functions

MacSurf's `libcss/include/libcss/types.h` adds three units upstream lacks:

```
CSS_UNIT_MIN    CSS_UNIT_MAX    CSS_UNIT_CLAMP
```

That is `min()`, `max()` and `clamp()` — modern responsive CSS, and nowhere in
§6.

Their presence has a side effect worth recording: building NetSurf core against
patched libcss fails with `-Werror=switch`, because
`content/handlers/css/dump.c` does not handle the new enum values. The core
lags the library until MacSurf's `browser/netsurf` patches are ported too
(§4).

## 2. Corrections to §6

| §6 says | Reality |
|---|---|
| "CSS transitions/animations (queued, not v1)" — **does not work** | **Wrong.** All four `transition-*` properties are implemented, plus two animation properties. |
| Phase 2 item 12 lists **transform (Q1)** as an open gap | **Wrong.** `macsurf_transform` is implemented, parse and select side. |
| Phase 2 item 12 lists **two-value `gap` (Q2)** as an open gap | **Partly wrong.** `row-gap` is added by MacSurf; `column-gap` already existed upstream. |
| Phase 2 item 12 lists `caption-side` (Q3), `table-layout: fixed` (Q4), multi-column (Q5) | **Still accurate** — all three exist upstream already; MacSurf's queue is about *correctness*, not presence. |
| "`<script type="module">`" — **does not work** | Already corrected in §13.5: real ES modules via `fixes1117b`. |
| "matchMedia", "*Observer stubs", "innerHTML reads as textContent" | Already corrected in §13.5. |

**Running total: §6 has now been found wrong in eight places** — the five
recorded in §13.5, plus transitions, transform, and the omission of `min()` /
`max()` / `clamp()`.

### 2.1 Claims that survive

- `<video>` / `<audio>` — no media pipeline. Unchanged.
- `<canvas>`, WebGL, WebGPU — `qjs_canvas_measure_text_width` exists, but there
  is no drawing surface. Effectively unchanged.
- Service workers — unchanged.
- HEIC / AVIF — unchanged.
- Heavy React/Vue SPAs — unchanged, and still the north-star question.

## 3. Why §6 drifted

§6 was written from MacSurf's published CSS status pages. Those pages describe
what MacSurf considers *shipped and verified on hardware*; the source contains
more than that, some of it presumably unverified. The lesson is the one already
recorded in `north-star.md`: **audit the source, not the documentation.**

This also means the corrections above are claims about *what is implemented*,
not about what is correct. Confirming behaviour is what the golden-plotstream
harness is for (`03-golden-plotstream.md`), and is the natural next step.

## 4. Recommended action

Rather than patch §6 line by line a ninth time, **replace it with a generated
capability list**. The property set is mechanically derivable from the tree:

```sh
for f in browser/libcss/src/select/properties/s_*.c; do
    stem=$(basename "$f"); stem=${stem#s_}
    [ -f "upstream/libcss/src/select/properties/$stem" ] || echo "${stem%.c}"
done
```

A generated list cannot drift. §6 should keep only the *categorical* claims —
no media, no canvas, no service workers — and defer the property inventory to
that list.
