# Phase 0 — the MacSurf patch stack

**Date:** 2026-09-21
**Covers:** brief §14.4 / `02-upstream-pivot.md` §6 item 4
**Status:** ✅ **62 patches, all applying cleanly to pristine upstream.**
⚠️ 3 of 5 libraries build from the stack; libcss and libdom have specific,
named blockers (§6).

> **Headline:** of the 121,604-line divergence, **86,539 lines carry no
> semantic value for a GCC/vitaSDK target** — CodeWarrior renames, committed
> build output, and `#include` rewrites chasing those renames. The real content
> is **26,796 lines in 62 patches**, median 123 lines each.

---

## 1. What the diff actually contained

| Class | Lines | Ported? |
|---|---:|---|
| CodeWarrior renames | 45,648 | ❌ excluded |
| Committed build output | 39,882 | ❌ excluded — regenerate instead |
| `#include` rewrites chasing renames | 987 | ❌ excluded |
| Whole-file deletions | 22 | ❌ excluded |
| **Real change** | **26,796** | ✅ **62 patches** |

### 1.1 Renames — the single biggest category

MacSurf renamed files to work around two CodeWarrior/Mac OS 9 constraints:
filename collisions across libraries, and the classic 31-character filename
limit. Three schemes, discovered in this order, each defeating the previous
detection rule:

```
errors.h              ->  ns_errors.h              (prefix)
border_radius.c       ->  p_border_radius.c        (per-directory prefix)
stylesheet.h          ->  css_internal_stylesheet.h
select/font_face.h    ->  css_internal_select_font_face.h   (path flattened
                                                             into the name)
```

**vitaSDK is GCC with a normal filesystem and has neither constraint**, so none
of this is ported. Chasing the schemes by guessing prefixes did not converge;
the splitter now indexes the upstream tree by every alias a file could be
referred to under (real path, basename, and path-with-slashes-flattened) and
resolves against that.

### 1.2 Build output MacSurf committed

CodeWarrior cannot run perl or gperf, so MacSurf committed generated sources:
`ag_*.c` (from `properties.gen` via `mkprops.pl`), libhubbub's `entities.inc`
and `entities_dict.h` (**34,463 lines between them**), `aliases.inc`.

We run perl and gperf, so we regenerate. `libcss/03-generator-input.patch`
carries the real change — **6 lines** in `properties.gen`, standing in for
2,498 lines of generated output.

## 2. The stack

| Library | Patches |
|---|---:|
| libcss | 46 |
| libdom | 8 |
| libhubbub | 5 |
| libwapcaplet | 2 |
| libparserutils | 1 |

**32 patches are attributed to a single MacSurf fix id** (`fixes1117b`,
`fixes1235`, …) and named for it. The remaining 30 are topic patches covering
files that carry no fix id, or several interleaved.

That split is deliberate. A file carrying exactly one fix id can be attributed
to that fix — the finest honest granularity the source supports. Files with
several would need hunk surgery to separate, and the result would no longer
apply independently. **Every patch here touches whole files only, so no two
patches touch the same file and the stack applies in any order.**

Twelve patches are one new CSS property each — `grid`, `grid-col-span`,
`grid-flow`, `grid-rows`, `gradient`, `transform`, `object-position`,
`text-shadow`, `dotgrid`, `hstripe-bg`, `animation-opacity`,
`animation-rotate` — parse side and select side together. These are the
cleanest units in the stack.

Size: median **123 lines**, **54 of 62 under 500 lines**. The four largest are
`08-parse-properties` (6,780), `34-select-cascade` (4,224),
`36-select-properties` (3,061) and `07-parse-core` (2,966); those resist
further splitting for the reason above.

## 3. Tooling

| Tool | Does |
|---|---|
| `tools/regen-patches.sh` | five whole-library diffs, relative paths, `-p2`-applicable |
| `tools/split-patches.py` | classify, exclude noise, rewrite references, emit the stack + `patches/MANIFEST.md` |
| `tools/apply-patches.sh` | apply the stack to a clean tree; `--dry-run` to verify |
| `compat/macsurf_debug.h` | shim for MacSurf's trace calls (see §5) |

All generated; regenerate rather than hand-editing `patches/`.

```
$ tools/apply-patches.sh --dry-run
applied: 62   failed: 0
```

## 4. Three transformations the stack has to perform

Excluding renames is only half the job — ported hunks still *refer* to renamed
files. Without these, nothing compiles:

1. **`#include` retargeting.** MacSurf flattens include paths, so
   `#include "hub_parserutilserror.h"` becomes `#include
   "utils/parserutilserror.h"` — the upstream *path*, not just its basename.
2. **Basename swaps outside includes.** `libcss`'s property `Makefile` lists
   `p_border_radius.c`; rewritten to `border_radius.c` or the build references
   a rename we did not port.
3. **Recovering renamed-*and*-modified files.** The subtle one.
   `css_internal_stylesheet.h` is a rename of `stylesheet.h` — but it *also*
   adds the `custom_properties` member that cascade-time `var()` needs.
   Excluding it as a rename silently dropped real work and compiled
   `stylesheet.c` against a struct missing the field. Those files are now
   diffed against their upstream counterpart and re-targeted at the upstream
   path, discarding the rename and keeping the change. **8,982 lines were
   recovered this way** — a third of everything ported.

   Matching is constrained to the *same directory*: several libraries carry
   more than one `utils.c`, and a basename-only match silently patches the
   wrong file.

## 5. `compat/macsurf_debug.h`

MacSurf's patches call `macsurf_debug_log_writef()` for hardware tracing, and
declare it *inside functions*, which upstream's `-Wnested-externs -Werror`
rejects. `harness/BUILD-NOTES.md` §"Layer 4" lists this as one of three stubs
any port must supply (`01-toolchain-and-desktop-build.md` §5.2).

Ours declares it at file scope and compiles the calls out by default behind
`VITABROWSER_ENGINE_TRACE`, while still type-checking their arguments so a
trace call cannot rot. Brief §8 item 1 — four debugging rounds lost to a silent
clamp — is why the option exists at all.

Build with `C_INCLUDE_PATH=$(pwd)/compat`, **not** `CFLAGS=-Icompat`: setting
`CFLAGS` on the make command line replaces the buildsystem's own `-Isrc` and
produces a confusing cascade of missing-header errors.

## 6. Build status and remaining blockers

```
libwapcaplet    ✅      libparserutils  ✅      libhubbub  ✅
libcss          ❌      libdom          ❌
```

Both failures are **semantic, not structural** — the patches apply, the files
are right, specific declarations are missing:

- **libcss** — `src/select/arena.c`: `MACSURF_CALC_SLOT_COUNT` undeclared,
  `css_computed_transition_data` unknown. Content still sitting in a
  renamed-and-modified header that the same-directory constraint in §4.3 does
  not reach (the declarations live under `include/`, not beside `arena.c`).
- **libdom** — `src/utils/hashtable.h`: `unknown type name 'bool'`. A missing
  `<stdbool.h>`; MacSurf gets it from a CodeWarrior prefix header that has no
  equivalent here.

Neither needs more splitter work. Both are ordinary porting: find the
declaration, carry it, rebuild.

## 7. Not done / blocked

- **`-Werror` is still relaxed to `-Wall`** for patched builds, because of the
  nested-extern trace declarations. Once `compat/macsurf_debug.h` is included
  early enough everywhere, restore `-Werror`.
- **No sudo in this session**, so nothing needing a system package was
  attempted. Nothing in this task required one.

## 8. Next actions

1. Fix the two §6 blockers; get all five libraries building from the stack.
2. Restore `-Werror` (§7).
3. **Capture golden plotstreams with the stack applied** and diff against the
   upstream goldens in `testpages/golden/`. That converts "MacSurf has CSS
   fixes" into a measured, page-by-page statement — and it is the first real
   use of the §14.3 harness.
4. Re-audit brief §6's capability matrix against the 12 property patches.
5. Split the four largest patches further if hunk-level attribution ever
   becomes worth the loss of independent applicability.
