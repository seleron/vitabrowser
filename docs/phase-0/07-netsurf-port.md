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


---

## 9. Stripping the scaffolding (2026-09-21, second session)

### 9.1 The split was not what the symbol names suggested

The plan was "strip 45, declare 10". Checking each symbol's **definition site**
rather than inferring from its name changed that materially:

| Defined in | Treatment | Examples |
|---|---|---|
| MacSurf's Mac OS 9 frontend | **strip** | `macsurf__site_*` (23), `macsurf_profile_*`, `macos9_heap_*`, `macos9_font_measure_*`, `macsurf_debug_log_int` |
| The netsurf files we port | **leave alone** | `macsurf_obj_fetch_stats`, `macsurf_llcache_stats`, `macsurf_img_ctor_stats`, `macsurf_imgdims_stats`, `macsurf_reconvert_seq`, `macsurf_box_backlink_cleared`, `macsurf__cascade_probe_armed` |
| libcss | **leave alone** | `css_inline_extras_clear` |

The middle row is the important one: those look like scaffolding, but they are
defined in core and **MacSurf writes a self-prototype immediately above each
definition** — `box_special.c:1794` declares `macsurf_imgdims_stats` one line
before defining it. Declaring them in compat turns a missing-prototype error
into a redundant-declaration error.

Only six functions were genuinely undeclared anywhere and needed compat
prototypes: `html_reconvert`, `html_reconvert_content`,
`html_macsurf_font_face_url`, `macsurf_html_has_droppable_inflight`,
`macsurf_reconvert_node_ref`, `macsurf_reconvert_node_unref`.

### 9.2 Stripping is at hunk granularity, all-or-nothing

MacSurf's site counters appear inside `if` conditions and a `switch`, so
dropping individual lines leaves dangling control flow. A hunk whose added
lines are *entirely* scaffolding is dropped, leaving upstream's code; a hunk
mixing scaffolding with real change is kept intact.

That is correct but not sufficient, which is the finding below.

### 9.3 ⚠️ The finding: mechanical classification does not converge

**The build oscillates.** `tools/split-patches.py` strips `extern`
declarations for whatever `compat/*.h` declares, so the patch set is a
function of the compat headers — and each compat change flips a set of symbols
between two failure modes:

- **Declared in compat** → its declaration is stripped from the tree → but
  MacSurf's own self-prototype or another header still declares it →
  `-Werror=redundant-decls`.
- **Not declared in compat** → its declaration survives → but it is a nested
  `extern` → `-Werror=nested-externs`; or its declaration was in a
  pure-scaffolding hunk that got dropped, while a *use* survived in a mixed
  hunk → `undeclared (first use in this function)`.

Both directions were tried. Neither state is clean, because **the correct
treatment differs per call site, not per symbol**: the same counter is
scaffolding in one hunk and interleaved with real layout work in another.

**Conclusion: the last four files need hand porting, not better rules.**
`content/handlers/html/html.c`, `layout.c`, `form.c` and `interaction.c` should
be ported by taking MacSurf's version, removing the instrumentation by hand,
and keeping the real change. That is a few hours of careful work on four files,
and it is the honest remaining cost — further rescue passes will keep trading
one error class for another.

### 9.4 Where the build stands

**264 of ~266 objects.** Four files fail. Two real code issues surfaced behind
the scaffolding and will need attention during the hand port:

- `comparison between 'css_unit' and 'enum css_intrinsic_kind_e'` — a genuine
  type confusion in MacSurf's layout changes.
- `comparison of integer expressions of different signedness` in the same area.

Several `defined but not used` warnings (`layout_dim_clamp`,
`layout_dim_sanitize_width`, `html_post_render_queue`) are functions whose only
callers were inside stripped scaffolding — they should be removed along with it
during the hand port, not silenced.

### 9.5 Task status

| Task | Status |
|---|---|
| (a) strip scaffolding, declare the ten | **done**, with the corrected split in §9.1 |
| (b) reach 266/266 | **not reached** — 264/266; §9.3 explains why and what it needs |
| (c) grid and flex probes | **already done** (commit `4d685c3`; `L3-grid`, `L4-flex`) |
| (d) re-run `compare-engines.sh` | **blocked on (b)** — needs a patched `nsmonkey`, which needs the netsurf build |

### 9.6 Not blocked by sudo

Nothing in this session needed root. The two demoted warnings
(`-Wno-error=unused-variable`, `-Wno-error=comment`) are build flags, not
package installs.

### 9.7 Workflow coupling worth knowing

The splitter strips `extern` declarations for whatever `compat/*.h` declares,
so **editing a compat header invalidates the patch set**. Two failures this
session were stale patches rather than bad code.
`tools/build-patched.sh` now regenerates the stack before building.


---

## 10. Hand-porting the four files (2026-09-21, third session)

### 10.1 The job was smaller than §9 assumed

Surveying before editing changed the shape considerably.

**Only `html.c` had instrumentation at all.** `layout.c`, `form.c` and
`interaction.c` have *zero* references to the `macsurf__site_` /
`macsurf_profile_` / `macos9_heap_` families — their failures were never about
scaffolding.

And of `html.c`'s 158 references, **49 are already inside `#ifdef __MACOS9__`**
and compile out untouched. Only 109 needed removing, in 14 regions, most of
them self-contained braced blocks.

### 10.2 What was removed from `html.c`

- The **SITE summary block** — 88 lines building one log line from ~23 frontend
  counters.
- Four pure-instrumentation blocks.
- The QuickDraw font-measure and Mac heap probes bracketing `layout_document`.
- The parse-chunk timing wrapper around `dom_hubbub_parser_parse_chunk`.
- Three `macsurf_profile_stamp` calls and the `macsurf_debug_log_int` calls.
- `html_post_render_queue` and `html_post_render_dispatch` — dead once their
  only callers went.

**Kept:** the real calls those wrapped (`layout_document`,
`dom_hubbub_parser_parse_chunk`), and every `macos9_micros` use, since compat
defines it.

### 10.3 The two real bugs, fixed

**`form.c`** — `form_atom_parse` set `out->literal` only on the two
`FATOM_LITERAL` paths while the caller copies the struct by value, so every
other kind left it indeterminate. All fields are initialised up front now;
`.literal` is only read when `kind == FATOM_LITERAL`, so this is
behaviour-neutral.

**`layout.c`** — three comparisons of a `css_unit` variable against
`CSS_INTRINSIC_MAX_CONTENT` / `_MIN_CONTENT`. libcss deliberately keeps
`enum css_intrinsic_kind_e` out of `css_unit` (properties.h says why: `css_unit`
has two free codes and three keywords are needed) and reuses the unit
sub-field to carry it when `type == *_INTRINSIC`. The comparisons are
semantically right and type-wrong; they now cast explicitly, and all three
reads were already guarded by the matching `*_INTRINSIC` check.

Also in `layout.c`: a signed/unsigned comparison (`int segment_index` against
`unsigned int segment_count`) now casts, the index being initialised to 0 and
only incremented.

### 10.4 The oscillation is fixed, by giving up on it

§9.3 recorded the build flipping between `redundant-decls` and
`nested-externs`/undeclared failures depending on what compat declared. The fix
was to stop fighting it: **the splitter no longer strips declarations** (only
instrumentation ones), and `-Wnested-externs` and `-Wredundant-decls` are
demoted for the netsurf build.

MacSurf's inline declarations are valid C; upstream objects only on style.
Two demoted style rules removed an entire failure class and the coupling that
made editing a compat header invalidate the patch set.

Demoted in total: `unused-variable`, `comment`, `nested-externs`,
`redundant-decls`. **Everything that catches real defects stays at `-Werror`** —
`implicit-function-declaration`, `missing-prototypes`, `sign-compare`,
`enum-compare`, `uninitialized`, `switch`.

### 10.5 Build status: 271 objects, two files

Progress across the session: **264 → 265 → 267 → 271**. Two files remain,
`redraw.c` and `script.c`, with a handful of missing declarations
(`js_fire_script_load`, `js_set_current_script`, `macos9_heap_*`) of exactly
the kind already solved several times.

### 10.6 ⚠️ `include/netsurf/plot_style.h` is missing from the stack

The most consequential finding of the session, and it is **not** a hand-port
issue.

`redraw.c` fails with `excess elements in struct initializer`: MacSurf
initialises `plot_style_t` positionally with seven elements, and the tree's
struct has five. Their `plot_style.h` is 359 lines against upstream's 288, and
the extra members are exactly the capability task 5 is meant to measure:

```
box_shadow_y   box_shadow_color   opacity
transform      transform_b        radial_set
radial_sx      radial_sy          radial_px   radial_py
```

**That header is in the raw diff with 85 lines of churn, survives every rescue
pass, is rejected by none of the exclusion rules — and still appears in no
generated patch.** That is a classifier bug, not a design decision, and it
means **the plotter extension carrying gradients, shadows, opacity and
transform is currently not ported at all**.

Which also means: had the build completed, `compare-engines.sh` would have
shown far less movement than expected, and the cause would have looked like
"MacSurf's CSS does not reach the plotters" rather than "one header went
missing". Worth finding before drawing any conclusion from task 5.

### 10.7 Task status

| Task | Status |
|---|---|
| (1) hand-port the four files | **done** — §10.1–10.2 |
| (2) fix the two real bugs | **done** — §10.3, plus the sign-compare |
| (3) remove now-unused functions | **done** — `html_post_render_queue`, `_dispatch`, and `layout_safe.h`'s helpers made `static inline` |
| (4) reach a clean build | **not reached** — 271 objects, two files left (§10.5) |
| (5) re-run `compare-engines.sh` | **blocked on (4)**, and see §10.6 before trusting its result |

Nothing needed sudo.

### 10.8 Next

1. **Find why `plot_style.h` is dropped** (§10.6). Highest value: it gates the
   entire gradient/shadow/transform path.
2. Finish `redraw.c` and `script.c` — the same declaration work as before.
3. Then task 5, with §10.6 resolved so the comparison means something.


---

## 11. The `plot_style.h` classifier bug (2026-09-21, fourth session)

### 11.1 Root cause

§10.6 recorded that `include/netsurf/plot_style.h` was in the raw diff with 85
lines of churn, survived every rescue pass, was rejected by none of the
exclusion rules, and still appeared in no generated patch.

The skip was happening in the main loop, **between** those two checks — the one
place not instrumented.

The C89 de-inlining rule worked at **file level**: if a file's `static inline`
count dropped to zero between upstream and MacSurf, the whole diff was skipped
as a CodeWarrior workaround. `plot_style.h` has exactly one `static inline`
helper upstream, which MacSurf de-inlined, so the entire file went — along with
the ten struct members it adds.

**A file-level test cannot distinguish a pure C89 workaround from a file that
has one *and* real work.**

### 11.2 What it was gating

```
box_shadow_y   box_shadow_color   opacity
transform      transform_b        radial_set
radial_sx      radial_sy          radial_px   radial_py
```

That is the entire gradient / shadow / opacity / transform plotter extension —
exactly what `compare-engines.sh` is meant to measure. Its absence is also why
`redraw.c` failed with `excess elements in struct initializer`: MacSurf
initialises `plot_style_t` positionally with seven elements against a
five-member struct.

### 11.3 The fix

The rule now works **per line**: where a removal is `static inline X` and the
following addition is the same line as `static X`, the original is kept and
everything else in the file ports normally.

The file-level skip survives only for the case it was actually written for —
MacSurf moving function bodies out to a `c89_helpers` `.c`, which genuinely
leaves declarations without definitions (`undefined reference to list_del`).

### 11.4 Seven files, not one

The same rule was discarding whole files across three libraries:

| File |
|---|
| `netsurf/desktop/bitmap.c` |
| `netsurf/include/netsurf/plot_style.h` |
| `libcss/src/utils/utils.h` |
| `libcss/src/utils/parserutilserror.h` |
| `libcss/src/select/select.h` |
| `libcss/src/select/computed.h` |
| `libwapcaplet/include/libwapcaplet/libwapcaplet.h` |

`libcss/src/select/computed.h` and `select.h` are not incidental — they are the
cascade's core headers. Whatever MacSurf changed in them had been silently
absent from every build in this project so far.

### 11.5 Lesson

Every single-rule test I ran against `plot_style.h` said "not excluded", and the
file survived all rescues with its churn intact. The failure was in code that
sat between the two things being checked. **When a classifier drops something
and no rule admits to it, instrument the loop, not the rules.**
