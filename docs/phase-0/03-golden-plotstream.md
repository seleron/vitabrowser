# Phase 0 — headless NetSurf, and golden plotstream testing

**Date:** 2026-09-21
**Covers:** `nsmonkey` build, live HTTPS fetch, and the §14.3 test mechanism
**Status:** ✅ **Phase 0 steps 4–5 achieved on the desktop backend.** A real
HTTPS page is fetched, parsed, styled, laid out and painted, and the paint
output is captured as a deterministic golden file at the Vita's viewport.

> **Headline:** §14.3 proposed golden-*image* diffing. That is the wrong
> mechanism — `nsmonkey` emits the entire paint stream **as text**, from the
> same plotter interface the Vita frontend will implement. Diff the plot calls,
> not pixels. Strictly better, and it works on-device over the UDP log.

---

## 1. `nsmonkey` builds and runs ✅

With the system dev packages installed, the full build succeeds with
JavaScript (Duktape) enabled:

```sh
make TARGET=monkey -j4     # -> nsmonkey, 12.7 MB
```

`nsgenbind` builds once `bison`/`flex` are present, which is what generates the
JS DOM bindings.

### Live HTTPS fetch, end to end

```
Action: navigate   win1 --> https://example.com/
Action: block      (status: complete)
        load took: 1.07s
```

**Fetch → HTML parse → CSS cascade → layout → paint, over real HTTPS, headless
on Linux, in ~1 s.** That is brief §9's Phase 0 steps 4–5, on the desktop
backend. The Vita half remains.

## 2. ⭐ The test mechanism: plot streams, not images

`frontends/monkey/plot.c` implements NetSurf's plotter table by printing each
operation:

```
PLOT CLIP X0 0 Y0 0 X1 960 Y1 544
PLOT RECT X0 0 Y0 0 X1 960 Y1 544
PLOT TEXT X 330 Y 173 STR Example Domain
PLOT TEXT X 330 Y 213 STR This domain is for use in
```

Those are real laid-out coordinates. The wrap points in that text *are* the
line breaker's output at 960 px.

### Why this beats golden images

| Golden PNG | Golden plotstream |
|---|---|
| varies with font rasterisation, AA, library version | exact integers, no rendering variance |
| "12,431 pixels differ" | `PLOT TEXT X 330 Y 213` → `X 330 Y 219` |
| binary blobs in git | text, reviewable in a diff |
| needs a framebuffer on-device | Vita frontend can print the same lines over UDP |

The last row is the important one. The Vita frontend implements the **same**
`struct plotter_table`. Instrument it to emit this format and a Vita-vs-desktop
layout diff needs no framebuffer capture, no image transfer and no debugger.
That is the answer to brief §2's "no debugger" row.

### Verified deterministic

Three consecutive captures of the same URL were **byte-identical**, and
identical again after a tool change. Volatile fields (heap pointers, poll
timings, window teardown) are masked or dropped.

## 3. Tooling added

| File | Purpose |
|---|---|
| `tools/plotstream.py` | drive `nsmonkey`, capture one page's plot stream as a golden file |
| `tools/check-goldens.sh` | re-capture every probe page, diff against committed goldens |
| `testpages/pages/L1-layout-basics.html` | first probe card: block, inline wrap, float, table |
| `testpages/golden/*.plot` | committed golden streams |

```
$ tools/check-goldens.sh
PASS L1-layout-basics
$ INCLUDE_NETWORK=1 tools/check-goldens.sh
PASS L1-layout-basics
PASS example-com (network)
```

Network-backed goldens are gated behind `INCLUDE_NETWORK=1`, since a remote
page can change under us and that is not our regression.

`L1-layout-basics` produces **108 plot operations** and exercises block boxes,
inline wrapping, a float (text correctly offset to `X 120`), and table cell
borders.

## 4. Four traps, all of which produce a *silently blank* capture

Each of these yields a plausible-looking file with ~2 plot ops instead of an
error. Worth knowing before trusting any capture.

1. **`nsmonkey` resolves its resource tree relative to the working directory.**
   Run it from anywhere else and every page renders empty. The tool now sets
   `cwd` to the binary's directory.
2. **The initial blank page emits its own `STOP_THROBBER`.** Waiting for the
   first one returns before the real navigation starts. Track this navigation's
   `START_THROBBER` first.
3. **Draining monkey's stdout from a reader thread puts it in an endless
   re-fetch loop** — `START_THROBBER / Fetching / Processing / Loading`
   repeating, 36,673 lines in 20 s, page never settles. Feeding commands on a
   timed schedule and collecting stdout to a file does not. Not root-caused;
   see §6.
4. **Masking heap pointers with `0x[0-9a-f]+` eats page content** — the string
   `200x60` contains `0x60`. Require a non-alphanumeric prefix and ≥6 hex
   digits.

## 5. Monkey's viewport is hardcoded — patched to the Vita's

`frontends/monkey/browser.c:85-86` hardcodes 800×600, and the core's
`window_width` / `window_height` options are ignored by this frontend. Patched
locally to **960×544** so desktop goldens are directly comparable with Vita
output:

```c
ret->width  = 960;  /* VitaBrowser: match Vita front screen */
ret->height = 544;  /* VitaBrowser: match Vita front screen */
```

This belongs in the patch stack as a **tooling** patch, kept separate from
engine patches (brief §14.4, and the MIT/GPL boundary noted in `LICENSE`).

## 6. Open question

The re-fetch loop in §4.3 is worked around, not understood. It reproduces
reliably: concurrent stdout drainage → endless refetch; timed writes with
file-collected stdout → clean load. Before building anything else on `monkey`,
someone should find out why, because it may indicate a fetch-layer or
scheduler assumption that will matter on the Vita, where we control the event
loop (brief §4, single-threaded `curl_multi`).

## 7. Next actions

1. **Root-cause §6** before extending the harness.
2. **Grow `testpages/`** into the §8 probe-card suite: flex, grid, custom
   properties, line breaking with U+00AD, tables without explicit widths. Each
   page numbered, each commit naming the card it fixes.
3. **Wire `monkey_driver.py`'s `plot-check` and `js-exec`** — already upstream —
   for assertion-style tests alongside whole-stream goldens. `js-exec` is the
   hook for north-star JS work.
4. **Capture goldens with MacSurf's patches applied** and diff against upstream:
   that is a direct, quantified measurement of what their CSS work actually
   changes, page by page.
5. **Vita side:** printf example → VPK → UDP log loop; then emit this same plot
   format from the Vita frontend and diff against these goldens.
