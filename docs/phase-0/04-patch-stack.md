# Phase 0 — the MacSurf patch stack

**Date:** 2026-09-21
**Covers:** brief §14.4 / `02-upstream-pivot.md` §6 item 4
**Status:** ✅ **61 patches, all applying cleanly to pristine upstream, and
all five libraries now build from the stack** (updated 2026-09-21; see §9 for
what the two original blockers turned out to be).

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

## 6. Build status

```
libwapcaplet ✅   libparserutils ✅   libhubbub ✅   libcss ✅   libdom ✅
```

All five build. §9 records what the two blockers actually were — the guesses in
the previous revision of this section were wrong in both cases.

## 9. What the two blockers actually were (2026-09-21)

Neither was "a missing declaration to carry over". Both were **classification
bugs in the splitter**, and fixing them surfaced four more classes of
CodeWarrior workaround that must not be ported.

### 9.1 `autogenerated_*` is not generated

`libcss/src/select/autogenerated_computed.h` is **committed upstream source**
despite its name — and it holds `MACSURF_CALC_SLOT_COUNT` and
`css_computed_transition_data`. The splitter excluded it on the name.

Name is not the test. The rule is now **"does upstream track it in git"**:
upstream ships it → source, patch it; only MacSurf has it → build output they
committed because CodeWarrior cannot run perl. A filesystem check is not enough,
because we build inside the upstream tree and generated files are sitting there.

### 9.2 Stacked rename prefixes

MacSurf stacks prefixes: `select.h` → `css_internal_select.h`. Stripping one
prefix leaves `internal_select.h`, which matches nothing, so the rename was
missed and the file shipped as a spurious new one. Prefixes are now stripped
repeatedly, and `internal_`, `utils_`, `core_` were added to the list.

### 9.3 Redirect shims at the original filename

MacSurf leaves a stub *at the old name* that includes the renamed real header:
`src/select/select.h` is six lines of `#include` pointing at
`css_internal_select.h`, which holds the real 174. Porting the stub overwrote
upstream's genuine `select.h` with a redirect to a file we do not have, and
every type it declared vanished — which is where `unknown type name
'css_select_state'` came from.

Files that are only preprocessor glue are now skipped, so the real content gets
carried onto the upstream name instead.

### 9.4 CodeWarrior C89 workarounds — two flavours

Both actively harmful on GCC:

- **Standard includes deliberately removed.** MacSurf's own comment:
  `/* stdbool.h removed for CW8 C89 -- prefix provides bool */`. CW8 lacks the
  header and a force-included prefix supplies the type; we have the header and
  no prefix. **This was the entire libdom blocker.** Such removals are now
  converted to context lines, so the include survives.
- **`static inline` moved out of headers.** CW8 has no `inline`, so MacSurf
  turned the definitions into `extern` declarations and put the bodies in
  `libdom_c89_helpers.c`. Porting that gives declarations with no definitions —
  `undefined reference to list_del`. Headers that lose their `static inline`
  are now skipped, as are files MacSurf marks `c89` in the name.

### 9.5 Directory-blind basename matching

`s_accent_color.c` is a MacSurf *addition* in `src/select/properties`, but
`accent_color.c` exists in `src/parse/properties`, so a basename-only match
rewrote the Makefile entry to a file that is never built there. Both the
Makefile rewriting and the renamed-and-modified matching are now constrained to
the same directory.

## 10. `patches/vitabrowser/` — our own port fixes

A second series, applied after the generated stack, for work that is ours
rather than MacSurf's.

**`01-libcss-makefile.patch`** teaches libcss's Makefiles about the property
files MacSurf added. They build from `MacSurf.mcp`, a CodeWarrior project that
lists sources independently, so **their own Makefiles never learned about the
44 properties they implemented** — the link fails on `css__cascade_accent_color`
and 43 siblings, plus `css__cp_*` for cascade-time `var()` in
`src/parse/custom_properties.c`.

Generated by `tools/gen-makefile-patch.py`, so it tracks the stack rather than
rotting.

### Recent `patches/vitabrowser/` entries (110–126)

Each patch's header comment is its full rationale; doc 10/11/12 have the
evidence.

| Patch | What |
|---|---|
| 110 | sim: VITA_SIM_SCRIPT scripted sessions (nav/eval need the engine) |
| 111 | JS element geometry always on (+ locked-content flush guard) |
| 112 | stacking contexts across levels; fixed stays put; clicks hit the top |
| 113 | libcss: lengths against a reference (calc with %), raw min-height auto |
| 114 | % / calc() heights and offsets; floated flex/grid; replaced boxes in flex |
| 115 | flex columns size their items (grow/shrink, max-height, auto min) |
| 116 | vita: drag scrolls the box under the finger |
| 117 | polyfill: on<event> on document/window, document.title, prototypes |
| 118 | script-built forms submit; pointer events on taps |
| 119 | rem relative to the root font size during the cascade |
| 120 | fixed boxes against the viewport; definite flex height; stacking-aware walks |
| 121 | inline `<svg>` painted with libsvgtiny |
| 122 | vita: pooled image textures (UID exhaustion fix); consent cookies |
| 123 | polyfill: listener objects, template.content, 73 missing DOM APIs |
| 124 | vita: SVG path fills by scanline, nonzero rule |
| 125 | polyfill: window.open stub (Hermes) |
| 126 | cross-realm frames + postMessage, JSON-only across runtimes (doc 12) |
| 127 | window.open opens a real popup window (window stack, opener bridge) |
| 128 | script-inserted scripts async + load/error; flex ignores abspos children |

## 7. Not done / blocked

- **`-Werror` is still relaxed to `-Wall`** for patched builds, because of the
  nested-extern trace declarations. Once `compat/macsurf_debug.h` is included
  early enough everywhere, restore `-Werror`.
- **No sudo in this session**, so nothing needing a system package was
  attempted. Nothing in this task required one.

## 8. Next actions

1. Restore `-Werror` (§7).
2. **Capture golden plotstreams with the stack applied** and diff against the
   upstream goldens in `testpages/golden/`. In progress — needs `nsmonkey`
   linked against the patched engine.
3. Port MacSurf's `browser/netsurf` changes. The core now lags the library:
   patched libcss adds `CSS_UNIT_MIN/MAX/CLAMP`, and
   `content/handlers/css/dump.c` does not handle them, so the core only builds
   with `-Wno-error=switch`. See `05-capability-reaudit.md` §1.1.
4. ~~Re-audit §6~~ — done, `05-capability-reaudit.md`. It found **44 added CSS
   properties**, not the 12 assumed here, and eight stale §6 claims.
5. Split the four largest patches further if hunk-level attribution ever
   becomes worth the loss of independent applicability.
