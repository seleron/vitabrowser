# Phase 0 — porting MacSurf's netsurf core

**Date:** 2026-09-21
**Covers:** `06-engine-comparison.md` §7 item 1 — the netsurf-side port
**Status:** stack extended to `browser/netsurf`; **89 patches, all applying**.
Build status in §5.

> **Why this task existed:** `06-engine-comparison.md` §3 found that patching
> only the five core libraries changed nothing visible for 42 of the 44 added
> CSS properties. libcss could cascade `box-shadow`; nothing asked it to draw
> one. The drawing lives in `browser/netsurf`.

---

## 1. Scope

`frontends/` is excluded from the diff. MacSurf's `macos9` frontend is 111k
lines we discard, and the Vita frontend will be written fresh against the same
plotter interface. What remains:

| Directory | Diff lines | Files |
|---|---:|---:|
| `content/` | 160,936 | 167 |
| `utils/` | 9,541 | 48 |
| `include/` | 7,145 | 121 |
| `desktop/` | 2,522 | 29 |

After classification: **29 netsurf patches, ~40k lines of real change.**

## 2. The patches that matter

| Patch | Files | Lines | Fix ids |
|---|---:|---:|---:|
| `14-html-layout.patch` | 27 | 22,444 | **384** |
| `05-css-handler.patch` | 4 | 8,579 | 71 |
| `01-content-core.patch` | 10 | 2,687 | 61 |
| `09-desktop.patch` | 10 | 1,108 | 30 |

`14-html-layout` is the port's centre of gravity — 384 distinct MacSurf fix ids
in one patch. It carries `layout.c`, `layout_flex.c`, `layout_grid.c`,
`box_construct.c`, `table.c`, **`redraw.c`**, **`redraw_border.c`**, and
`script.c` (the `type="module"` dispatch from §13.5).

That is exactly the pair `06-engine-comparison.md` §3 identified as missing:
the plotters and the box model's use of the new properties.

### 2.1 The redraw path gains real capability

Counting identifiers on added lines in `14-html-layout.patch`:

```
104  gradient          33  box_shadow        14  PLOT_OP_TYPE_LINEAR_GRADIENT
 45  transform         11  border_radius     17  PLOT_OP_TYPE_SOLID
```

`PLOT_OP_TYPE_LINEAR_GRADIENT` is a **new plot operation type**. This is the
concrete reason to expect the L2 comparison to change once this builds: the
engine can now emit gradient fills, and the redraw path knows about shadows and
rounded borders.

## 3. Three new classes of CodeWarrior workaround

Extending the splitter to netsurf surfaced three more, on top of the six
already recorded in `04-patch-stack.md` §9.

### 3.1 Vendored library headers that shadow the real ones

MacSurf copies the public headers of every library into
`netsurf/include/{curl,dom,hubbub,nsutils,parserutils}` so the CodeWarrior
project can find them. **Upstream netsurf has only `include/netsurf`.**

We install the real headers into a prefix, so these copies do not merely
duplicate — they *shadow*. `netsurf/include/dom/dom.h` includes
`dom/events/dom_events.h`, a filename that exists only in MacSurf's flattened
world, so the build failed on a header that was correct everywhere we looked.
**6,324 lines**, now excluded.

### 3.2 netsurf has no `src/`

The include index was built by stripping `src/` and `include/` prefixes, which
is right for the five libraries. netsurf is `content/`, `desktop/`, `utils/`,
and includes relative to the tree root — so `#include "utils/errors.h"`
resolved to nothing and every rename rewrite in netsurf silently failed.

The index now holds both forms. Order matters: the stripped form must be
registered first, because a library's own sources say `#include "stylesheet.h"`,
not `#include "src/stylesheet.h"`, and `setdefault` keeps the first mapping.
Getting that backwards broke libcss and libdom in a way that looked unrelated.

### 3.3 Duplicate definitions behind a shared guard

MacSurf defines `enum content_debug` in *two* headers —
`include/netsurf/content_type.h` and `include/netsurf/browser_window.h` — each
wrapped in `#ifndef MACSURF_CONTENT_DEBUG_ENUM`. Whichever is included first
wins. That is a correct mechanism, but only if **both** copies are ported.

Our include-churn filter treated `#ifndef`/`#define`/`#endif` as noise, so
`content_type.h`'s guard was dropped while `browser_window.h`'s copy was kept.
The guard was never defined, both definitions landed, and the build failed with
`redeclaration of enum content_debug` on a file byte-identical to upstream.

The filter now skips only `#include` directives, blanks and comments. **Guard
macros are content, not noise.**

## 4. Running exclusion totals

| Class | Lines |
|---|---:|
| Whole-file deletions | 117,718 |
| CodeWarrior renames | 53,501 |
| Committed build output | 34,755 |
| Vendored library headers | 6,324 |
| `#include` rewrites | 1,095 |
| C89 workarounds | 558 |
| Redirect shims | 80 |
| **Ported** | **71,496** |

Of the ported total, 2,431 lines were recovered from files MacSurf both renamed
and modified.

## 5. Build status

`tools/apply-patches.sh` applies all 90 patches (89 generated + 1 local) with
no failures, and the five core libraries build.

**netsurf core is being built with `-Werror` intact** — no `-Wno-error`, which
is the condition `06-engine-comparison.md` §6 recorded as blocked. Whether it
holds is the open question at the time of writing; §6 of this document records
the outcome.

## 6. Outcome

*(Filled in below once the build settles — see the commit that follows.)*
