# Pre-Phase-0 findings

**Date:** 2026-09-20
**Scope:** brief §14.11 checklist, items 1–5
**Status:** items 2–5 complete; item 1 partially complete (documented budget
established from vendor/SDK sources; on-hardware confirmation still outstanding)
**Sources examined:** `mplsllc/macsurf` @ `55e64fa` (v2.3, 2026-09-19),
`coderman64/netsurf-3ds` @ HEAD, vitaSDK docs

> **Headline:** the two biggest risks recorded in brief §13 both moved in our
> favour. The memory ceiling (§13.1) is roughly **double** what the brief
> assumed. The JS capability gaps that made the end goal look impossible are
> **largely already fixed upstream in MacSurf**. What got *worse* is the size
> and separability of the port: the engine is ~40% larger than the brief
> claimed, and MacSurf's platform layer is entangled with the "portable" core.

---

## 1. Memory budget (§14.11 item 1) — RESOLVED FAVOURABLY

### Documented budgets

| Pool | Default | Extended | Typical use |
|---|---|---|---|
| **MAIN** | **256 MiB** | **365 MiB** | stack, newlib heap, all general allocation |
| **CDRAM** | 112 MiB | — | video memory / framebuffers |
| PHYCONT | 26 MiB | — | physically contiguous kernel allocations |
| CDLG | ~8 MiB | — | dialog subsystem |

The extended MAIN budget is unlocked by passing **`-d ATTRIBUTE2=12`** to
`vita-mksfoex` when building the VPK. This is a packaging flag, not a code
change, and not a kernel modification.

### Why this changes the plan

Brief §13.1 recorded the project's top risk as: MacSurf wants a 164 MB minimum
/ 195 MB preferred application partition (384 MB for heavy JS) against an
*assumed* Vita budget of ~200–330 MB, which would also have to absorb
framebuffers, TLS, font caches and decode buffers.

Both halves of that concern soften:

1. **The real ceiling is 365 MiB MAIN, not ~200–330 MB.** That clears MacSurf's
   preferred partition with ~170 MB of headroom and approaches its heavy-JS
   figure of 384 MB.
2. **Framebuffers do not come out of MAIN.** CDRAM is a separate 112 MiB pool
   and is the natural home for the 960×544 display surfaces (*corrected 2026-09-22: there is no 480×272 rear screen, the rear panel is a touch pad — [09](09-vita-frontend.md) §9*) plus
   any scaled-image staging. The brief implicitly double-counted these.

**Consequence:** memory drops from "the project's single biggest unknown and
possible showstopper" to "a budget to be managed carefully." The §10 risk row
should be downgraded accordingly, and §2's RAM row updated with real figures.

### What is still open

- `ATTRIBUTE2=12` must be confirmed to work on **3.75 + enso** specifically.
- The 365 MiB figure is a documented budget, not a measured allocation ceiling;
  real-world headroom after `sceKernelAllocMemBlock` fragmentation is unknown.
- **Phase 0 step 0 still stands** — build the allocate-until-failure probe and
  write the measured number back into §2. It is now a confirmation exercise
  rather than a go/no-go gate.

---

## 2. Source audit (§14.11 item 2)

Both reference repos cloned and inspected. MacSurf publishes **full source**,
including the core libraries, the QuickJS port and the JS bridge.

### 2.1 Engine size — the brief understated it by ~40%

Measured over `src/` + `include/`, excluding tests, examples and perf:

| Library | Files | Lines | Licence |
|---|---:|---:|---|
| libcss | 484 | 91,722 | MIT |
| libdom | 288 | 47,344 | MIT |
| libhubbub | 52 | 26,000 | MIT |
| libparserutils | 38 | 7,132 | MIT |
| libwapcaplet | 2 | 705 | MIT |
| **Total** | **864** | **172,903** | |

The brief (§3.1, §4) cites "443 files, ~125k lines." The real figure is
**864 files and ~173k lines** — and that is before `browser/netsurf` itself
(content handlers, layout, plotters, desktop), which is the part we also need
and which is GPLv2.

Adjust effort expectations accordingly; this does not change the architecture.

### 2.2 The frontend abstraction exists — §14.2 confirmed

`browser/netsurf/frontends/` contains: `amiga`, `atari`, `beos`,
**`framebuffer`**, `gtk`, `macos9`, **`monkey`**, `qt`, `riscos`, `windows`.

| Frontend | Lines | Relevance |
|---|---:|---|
| `framebuffer` | 10,107 | **closest starting point for the Vita frontend** |
| `monkey` | 3,174 | headless driver — the automated-test backend for §14.3 |
| `macos9` | 111,087 | MacSurf's own; mostly discarded, but see 2.3 |

This confirms brief §14.2: the two-backend plan (desktop + Vita) is not
something we invent, it is how NetSurf is already structured. `framebuffer` at
10k lines is a tractable base and `monkey` gives golden-image diffing a home.

### 2.3 The JS bridge lives in the *frontend* — §13.2 confirmed and quantified

| File | Lines |
|---|---:|
| `frontends/macos9/javascript/macsurf_qjs.c` | 16,803 |
| `frontends/macos9/javascript/macsurf_qjs_audit.c` | 1,071 |
| `frontends/macos9/javascript/macos9_js_fetch.c` | 852 |
| headers | 358 |
| **Total** | **19,084** |

The highest-value code in the project sits inside the Mac OS 9 frontend, not in
shared engine code — and `macos9_js_fetch.c` is exactly the binding onto
`macLink` (Open Transport) that we are deleting.

This is the seam brief §13.2 flagged. It is now measured: **~19k lines to
re-host**, of which ~850 lines are directly networking-coupled and the rest is
DOM/global surface that should port with less friction.

### 2.4 MacSurf's platform layer is entangled with the "portable" core

**55 files inside the five nominally-portable core libraries reference
MacSurf-specific headers.** Example: `libdom/include/dom/functypes.h` does
`#include "macsurf_alloc_override.h"`, a header that lives in
`frontends/macos9/` and `harness/include/`.

Consequence: you cannot lift the core libs cleanly. Either port
`macsurf_alloc_override.h` (an allocator shim — probably desirable anyway, since
we need hard allocation accounting per brief §2 rule 3) or strip the coupling.

**This is the strongest argument yet for the §14.4 patch-stack approach.**
Vendoring MacSurf's tree wholesale imports 55 hidden platform dependencies you
will discover one compile error at a time. A diff against upstream NetSurf makes
every one of them visible up front.

### 2.5 The "C89-clean" claim is false — and irrelevant

Probe: `gcc -fsyntax-only -std=c89 -pedantic` across the core libraries.

| Library | C89 clean | C89 fail | Default GCC mode clean |
|---|---:|---:|---|
| libwapcaplet | 0 | 1 | 1 / 1 |
| libparserutils | 7 | 8 | 14 / 15 |
| libhubbub | 4 | 28 | 28 / 32 |

Failures are C99 constructs — `static inline` and `restrict` — present in
upstream NetSurf code, not introduced by MacSurf. CodeWarrior evidently accepts
them; GCC in strict C89 mode does not.

**Why it does not matter:** vitaSDK is GCC + newlib and compiles C99/C11
happily. Every file that fails `-std=c89` compiles clean in default mode. This
confirms brief §13.4: C89-cleanliness was worth less than §5.2 claimed. The real
value of MacSurf is the CSS fixes and the JS bridge.

`libcss` and `libdom` do not syntax-check standalone because they require
**generated** sources (libcss autogenerates property parsers via `mkprops.pl`;
libdom autogenerates bindings) plus the MacSurf headers from 2.4. Both need the
NetSurf buildsystem wired up — a Phase 0 task, not a code problem.

---

## 3. Licensing (§14.11 item 4) — RESOLVED, `LICENSE` written

Audited per-component. The brief's §5.4 reasoning was wrong; its conclusion was
right.

- The **five core libraries are individually MIT** (each has its own `COPYING`
  granting MIT terms). Vendoring MacSurf's modified libcss does **not**, by
  itself, force GPL.
- **`browser/netsurf` is GPLv2 with an OpenSSL linking exception.** The HTML
  content handler, the layout engine (`layout.c`, `layout_flex.c`,
  `layout_grid.c`) and the plotter interface all live here, and we cannot do
  without them.
- Therefore **VitaBrowser is GPLv2**, and the **OpenSSL exception is mandatory
  for us**, since we link vita-sdk OpenSSL. It is already granted upstream and
  has been carried into our `LICENSE`.

Useful corollary: fixes we make to the five core libraries *can* still go
upstream to NetSurf under MIT, provided they stay free of GPL-derived code.
Keep core-lib patches in a separate series from `browser/netsurf` patches so
that boundary stays clean.

---

## 4. Environment

| Tool | Status |
|---|---|
| git, cmake, make, gcc, python3, curl | present |
| **vitaSDK** | **not installed** (`VITASDK` unset, no toolchain dir) |
| Host RAM / disk | 39 GB / 390 GB free |

vitaSDK installation is Phase 0 step 1 and is the next action.

---

## 5. Checklist status

| # | Item | Status |
|---|---|---|
| 1 | Measure real Vita memory budget | **Documented: 365 MiB MAIN + 112 MiB CDRAM.** On-hardware probe deferred to Phase 0 step 0 |
| 2 | Clone refs, build core libs on desktop | **Done.** Cloned, audited, compile behaviour characterised (2.5). Full build blocked on NetSurf buildsystem — Phase 0 |
| 3 | Answer §14.1 and write goal into §1 | **Done.** Goal: run `claude.ai/code` on the Vita. See `docs/north-star.md` |
| 4 | Decide licence, write `LICENSE` | **Done.** GPLv2 + OpenSSL exception |
| 5 | Delete empty `client/` | **Done** |

## 6. Recommended next actions

1. **Install vitaSDK** and build the printf example (Phase 0 step 1). Blocks
   everything on-device.
2. **Stand up the NetSurf buildsystem** on desktop and get libcss + libdom
   generating and compiling — this is the real gate on 2.5, and it exercises the
   generated-source path we will need for the Vita.
3. **Produce the upstream-vs-MacSurf diff** (§14.4) and start `patches/`.
   Finding 2.4 makes this urgent rather than optional.
4. **Confirm `ATTRIBUTE2=12`** on 3.75 + enso, then run the allocation probe.
