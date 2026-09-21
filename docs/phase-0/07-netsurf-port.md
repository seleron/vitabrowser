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

## 6. Six more workaround classes, found by building

§3 listed three classes found while wiring netsurf into the splitter. Getting
the core to actually compile surfaced six more. Each one failed in a way that
pointed at the wrong file, so they are recorded with the symptom as well as the
cause.

### 6.1 Escaped-quote corruption in MacSurf's own tree

```c
const char *d; d = headers[i] + SLEN(\"If-None-Match:\");
```

An opening paren followed by an escaped quote is never valid C. Three files
carry it — `content/fetchers/file/file.c`, `content/fetchers/resource.c`,
`content/handlers/css/dump.c` — evidently a botched sed during MacSurf's own
C89 declaration-splitting pass. **They never noticed because their CodeWarrior
project does not compile those files.**

*Symptom:* `missing terminating " character`, `unterminated argument list
invoking macro "SLEN"`, `expected declaration or statement at end of input`.

The rescue keeps the upstream line, and is deliberately narrow: an escaped
quote *inside* a string literal is legitimate, and `dump.c` has a real one —
`fprintf(stream, "uri(\"%.*s\")", ...)`. The first pattern I wrote matched that
too.

### 6.2 `bool` → `unsigned char`

CW8 C89 has no `bool`, so MacSurf rewrote declarations throughout. On GCC this
is worse than unnecessary: libwapcaplet's public API still takes `bool *`.

*Symptom:* `initialization of '_Bool *' from incompatible pointer type
'unsigned char *'` — reported against libwapcaplet's header, which is
byte-identical to upstream.

Two forms needed handling. Paired (`-bool x = false;` / `+unsigned char x = 0;`)
required normalising the literal as well as the type. Unpaired — where MacSurf
rewrote a whole function so the declaration arrives as a pure addition —
required rewriting `unsigned char <name> = 0;` directly. Only that exact scalar
form; `unsigned char` is a legitimate type here for byte buffers.

### 6.3 Core additions declared only in the frontend

MacSurf added real functions to netsurf's core — `fetch_pump`,
`box_construct_sched_pins`, `macos9_box_walk_owns_content`,
`macsurf_box_freed_lookup`/`_note`, `macsurf_lazyimg_viewport_changed` — but
declared them in their Mac OS 9 frontend, which we do not port.

*Symptom:* `-Werror=missing-prototypes`.

`compat/macsurf_core_decls.h` supplies them, force-included into the netsurf
build. `fetch_pump` is worth keeping deliberately: it drives the fetch state
machine each event-loop iteration so queued jobs start, which is exactly the
shape brief §4's single-threaded `curl_multi` loop needs.

### 6.4 `extern` declarations that are redundant one way and required the other

MacSurf declares its helpers where it calls them. Upstream builds with **both**
`-Wnested-externs` and `-Wredundant-decls`, which cannot both be satisfied by
adding a header — without one you get the first, with one you get the second.

The splitter now strips `extern` declarations, at function scope *and* file
scope, for symbols declared elsewhere. That keeps both warnings at error level
rather than demoting a third.

**But the treatment has to differ by consumer**, which cost two rounds:

- **netsurf** already declares these in `content_protected.h`, so stripping the
  duplicates in `.c` files is exactly right.
- **the libraries** had the nested `extern` as their *only* declaration.
  Stripping it gave `incompatible implicit declaration of
  macsurf_debug_log_writef`.

So `compat/macsurf_debug.h` is now the `MS_LOG` macro only, and
`compat/macsurf_lib_decls.h` carries the declaration and is force-included into
the libraries alone. Putting it in the shared header instead trips
`-Werror=redundant-decls` in netsurf, because `content.c` includes that header
by name.

### 6.5 Frontend coupling in core

Core sources include `macsurf_debug.h` (17), `macos9_deathrow.h` (6),
`macsurf_debug_log.h` (2) and `macsurf_diag.h` (1), and call ~8 frontend
symbols. `compat/` supplies all of them; the reasoning for each behaviour is in
the headers, and the substantive one is the deathrow queue — MacSurf defers
teardown because Mac OS 9's cooperative scheduler can re-enter the core from a
callback, ours cannot, and upstream frees directly at those call sites, so the
shim runs the teardown immediately.

One collision to note: `macos9_content_is_live` and friends are guarded by
`#ifdef __MACOS9__` with macro fallbacks in the `#else` branch we compile.
Declaring them in compat as well made the macro expand inside the declaration —
`expected identifier or '(' before numeric constant`.

### 6.6 `-Werror=switch` was NOT unblocked by this port

`06-engine-comparison.md` §6 recorded the `dump.c` switch failure as something
the netsurf-side port would fix. **It does not.** MacSurf's `dump.c` has no more
knowledge of `CSS_UNIT_MIN`/`MAX`/`CLAMP` than upstream's does — zero
occurrences in both trees — because their CodeWarrior project does not build
with `-Werror=switch`.

The fix is ours: `patches/vitabrowser/03-netsurf-dump-new-units.patch`.

This is worth remembering as a pattern: **MacSurf's tree only compiles cleanly
under the warning set CodeWarrior applies.** Anything upstream's `-Werror`
catches that theirs does not, they will not have fixed.

## 7. Build recipe

`tools/build-patched.sh` stages clean upstream trees, applies the stack and
builds through to `nsmonkey`. The flags are load-bearing and documented in its
header; the two force-includes differ by consumer per §6.4, and
`C_INCLUDE_PATH` is used rather than `CFLAGS` because a `CFLAGS` on the make
command line replaces the buildsystem's own `-Isrc`.

Current `-Werror` position: libraries at `-Wall`; netsurf at full `-Werror`
except `-Wno-error=unused-variable`, for MacSurf's debug leftovers (`ua`, `na`
in `content_broadcast`) which are assigned and never read. One demoted warning,
still printed, rather than the blanket `-Wno-error` this started with.

## 8. Outcome — substantially advanced, not finished

**All 90 patches apply. All five libraries build. netsurf core compiles 263 of
its ~266 objects.** Three files do not: `content/handlers/html/box_construct.c`,
`form.c` and `html.c`.

Progress across this session, measured by where the build stopped:

| | |
|---|---|
| Start | netsurf did not compile at all (vendored headers shadowing the real ones) |
| End | **263 objects; 3 files remaining** |

### 8.1 What is left is one problem, not a tail

The three remaining files produce ~85 errors across **53 distinct symbols**, and
they are not 53 distinct problems. They are MacSurf's instrumentation surface,
which is far denser in these files than anywhere else in the tree:

| Category | Symbols |
|---|---:|
| Per-site statistics counters (`macsurf__site_*`) | 23 |
| Other diagnostics (logging, object stats, reconvert tracking) | 13 |
| Profiling / timing (`macsurf_profile_*`) | 5 |
| **JS bridge hooks** (`js_fire_dom_ready`, `js_thread_valid_for_content`, …) | **5** |
| **Genuine engine** (`browser_window_set_status`, `macos9_schedule`, …) | **5** |
| Mac heap and font probes (`macos9_heap_*`) | 4 |

**45 of the 53 are debug scaffolding** — counters and timers MacSurf added to
hunt a use-after-free on their own hardware. They have no bearing on rendering.

### 8.2 The decision this needs

Continuing by stubbing all 53 in `compat/` would work but is the wrong shape:
it imports 45 symbols' worth of someone else's debugging apparatus into our
engine, permanently.

The better split, and the next task:

- **Strip the instrumentation.** `macsurf__site_*`, `macsurf_profile_*`,
  `macos9_heap_*`, `macsurf_debug_log_int`, the `_stats` family. These are
  observation-only; the brief's own §8 lesson about logging every defensive
  clamp is served by `VITABROWSER_ENGINE_TRACE`, not by 23 site counters.
- **Keep and declare the 10 that matter.** The five JS bridge hooks are real
  behaviour — they are how the DOM signals the script thread — and the five
  engine calls are ordinary netsurf API that only needs the right header.

That is a content decision about what we are porting, not another rescue pass,
which is why this document stops here rather than pressing on.

### 8.3 Two warnings still demoted

- `-Wno-error=unused-variable` — MacSurf's `ua`/`na` in `content_broadcast`,
  assigned and never read.
- `-Werror=comment` will need demoting or patching: `form.c` has a comment
  reading `Sets *min/*max to`, and `*max` after `/` reads as a nested `/*`.

Everything else is at full `-Werror`, including `-Wredundant-decls`,
`-Wnested-externs` and `-Wmissing-prototypes`, which took the §6.4 split to
achieve.

### 8.4 Correction to the task premise

`-Werror=switch` on `dump.c` was expected to be unblocked by this port. It was
not — see §6.6. That fix was ours to make, and it is made
(`patches/vitabrowser/03`).
