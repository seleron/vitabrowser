# Phase 0 — pivot to upstream NetSurf, and the MacSurf patch stack

**Date:** 2026-09-20
**Covers:** the §14.4 pivot, the measured MacSurf divergence, headless `monkey`
**Status:** upstream libs ✅ all five build clean. `monkey` ⚠️ **compiles
completely (140 objects), fails only at link** on deliberately-disabled image
handlers. Unblocking it needs system dev packages.

> **Headline:** the pivot is decisively validated. **All five upstream libs
> built clean on the first attempt with `-Werror` intact** — the same five that
> could not be built from MacSurf's tree at all. And the versions match exactly,
> so the MacSurf diff is pure signal.

---

## 1. Versions match exactly — the diff is clean signal

| Library | MacSurf | Upstream | |
|---|---|---|---|
| libwapcaplet | 0.4.3 | 0.4.3 | ✅ |
| libparserutils | 0.2.5 | 0.2.5 | ✅ |
| libhubbub | 0.3.8 | 0.3.8 | ✅ |
| libcss | 0.9.2 | 0.9.2 | ✅ |
| libdom | 0.4.2 | 0.4.2 | ✅ |

MacSurf branched and never rebased. A plain recursive diff therefore isolates
**exactly** their changes, with zero version drift mixed in. This is the single
most favourable possible condition for a patch stack and it makes §14.4 cheap.

## 2. Upstream builds clean; MacSurf's tree does not

```
libwapcaplet  exit=0     libparserutils exit=0     libhubbub exit=0
libcss        exit=0     libdom         exit=0
```

First attempt, `-Werror` intact, no workarounds — versus MacSurf's tree, which
needed `-Werror` dropped, generated-file `touch`ing, an include-path fix, and
still failed on a stale Makefile (see `01-toolchain-and-desktop-build.md` §4).

**Confirms the pivot.** Build on upstream; apply MacSurf as patches.

Gotcha worth recording: the buildsystem must be installed into *each* prefix
you use — `NSSHARED` defaults to `$(PREFIX)/share/netsurf-buildsystem`, and a
missing one fails obscurely with `No rule to make target '/Makefile.top'`.

## 3. Measured MacSurf divergence

Excluding upstream test suites (we do not port them; libdom's tests alone were
644 of its 935 changed files):

| Library | Diff lines | Files | New `macsurf_*` files |
|---|---:|---:|---:|
| libwapcaplet | 183 | 2 | 0 |
| libparserutils | 734 | 11 | 0 |
| libhubbub | 37,994 | 31 | 0 |
| libcss | **61,928** | 332 | **24** |
| libdom | 20,765 | 291 | 0 |
| **Total** | **121,604** | **667** | **24** |

Verified *not* inflated by line endings — MacSurf's files are plain LF, and
`--strip-trailing-cr` changes the count by zero.

### 3.1 Where the value is concentrated

`libcss` dominates, and within it:

| Area | Files changed |
|---|---:|
| `src/parse` | 191 |
| `src/select` | 118 |
| `include/libcss` | 8 |

Plus **24 entirely new property implementation files**, which are the "CSS
superset" the brief claimed — now confirmed by name:

```
p_macsurf_grid.c          p_macsurf_grid_col_span.c   p_macsurf_grid_flow.c
p_macsurf_grid_rows.c     p_macsurf_gradient.c        p_macsurf_dotgrid.c
p_macsurf_animation_opacity.c   p_macsurf_animation_rotate.c   ...
```

Note `p_macsurf_animation_*` — brief §6 lists CSS animations as *not supported*.
That is another stale entry, alongside the four already corrected in §13.5.
**Re-audit §6 against the patch set before treating any of it as settled.**

### 3.2 What this means for the patch stack

121k lines is large but tractable **because the surface is legible**: one
library holds half of it, 24 files are pure additions, and the remainder
concentrates in two directories.

Splitting this into logical per-fix patches is real work and is **not yet
done** — `tools/regen-patches.sh` currently produces five whole-library diffs.
That script is the reproducible starting point, not the finished stack. The raw
diffs (3.7 MB) are intentionally **not committed** until they are split; a
single unreviewed 121k-line blob in git is not a patch stack, it is a fork with
extra steps.

## 4. Headless `monkey` — compiles fully, fails at link

```
make TARGET=monkey NETSURF_USE_DUKTAPE=NO ... -j4
→ 140 object files built
→ /usr/bin/ld: undefined reference to `nsjpeg_init'
```

**The entire NetSurf core compiles on Linux.** The only failure is link-time:
`content/handlers/image/image.c:71` still references `nsjpeg_init` even with
`NETSURF_USE_JPEG=NO`, so the disable flag is not fully wired upstream.

Rather than fight the disable flags, install the real dev packages — the
handlers we are disabling are ones we want anyway.

### 4.1 Missing system dependencies

| Need | For |
|---|---|
| `libjpeg-dev`, `libpng-dev`, `libwebp-dev` | image handlers (the link failure) |
| `libssl-dev` | HTTPS |
| `libfreetype-dev`, `libharfbuzz-dev` | text |
| `bison`, `flex` | **`nsgenbind`** — generates the JS DOM bindings |

```sh
sudo apt-get install -y libjpeg-dev libpng-dev libwebp-dev libssl-dev \
                        libfreetype-dev libharfbuzz-dev bison flex
```

`bison`/`flex` matter beyond the image handlers: without `nsgenbind` there are
no JS DOM bindings at all, so any JS-enabled build is blocked on them.

### 4.2 Include-path quirk

`libutf8proc` installs its header to `$PREFIX/include/libutf8proc/utf8proc.h`,
but `utils/idna.c` does `#include <utf8proc.h>` and pkg-config only emits
`-I$PREFIX/include`. Add `-I$PREFIX/include/libutf8proc` to `CFLAGS`. Upstream
packaging quirk, not ours.

## 5. ⭐ NetSurf ships monkey test infrastructure

`upstream/netsurf/test/` contains **`monkeyfarmer.py`**, **`monkey_driver.py`**
and **`monkey-see-monkey-do`**, with `docs/using-monkey.md`.

`monkey` is not merely a headless frontend — it is a **scriptable one with a
driver harness already written**. Combined with `harness/BUILD-NOTES.md`'s
independent endorsement of the same approach
(`01-toolchain-and-desktop-build.md` §5.1), brief §14.2 and §14.3 are now
standing on existing, maintained infrastructure rather than on a plan.

**Read `docs/using-monkey.md` before designing anything for §14.3.**

## 6. Next actions

1. **Install the §4.1 packages**, then finish the `monkey` link. That yields a
   working headless NetSurf on the desktop — the §14.2 backend.
2. **Build `nsgenbind`** (needs bison/flex) and re-enable JS, so the bridge work
   has somewhere to land.
3. **Read `docs/using-monkey.md`** and stand up the §14.3 golden-image loop on
   top of `monkey_driver.py`.
4. **Split the patch set** (§3.2) into logical per-fix patches, libcss first
   since it holds half the diff and all 24 new files.
5. **Re-audit brief §6** against the patch set — §3.1 shows the capability
   matrix is stale in at least one more place (CSS animations).
6. **Vita side, unchanged:** printf example → VPK → UDP log loop, then the
   Phase 0 step 0 allocation probe.

## 7. Working tree

```
<WORK>/vitabrowser-work/
├── upstream/          upstream NetSurf: 5 core libs + netsurf + 6 support libs + nsgenbind
├── upstream-prefix/   built + installed upstream libs (11 .a) ✅
├── browser/           MacSurf's tree (reference for diffing)
├── buildsystem/       netsurf-buildsystem (git:// only — mirror it)
└── patches/           generated diffs, 3.7 MB, not committed (see §3.2)
```

Regenerate the patch set with `tools/regen-patches.sh`.
