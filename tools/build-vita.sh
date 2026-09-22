#!/bin/sh
# Cross-build the patched engine and the Vita frontend into a VPK.
#
# Runs after tools/build-patched.sh, which stages the patched trees in
# $WORK/applytest/upstream (the Vita build reuses them; object directories
# are per-host, so the two builds never share objects).
#
#   1. the five MacSurf-patched engine libraries, for arm-vita-eabi
#   2. NetSurf's support libraries (nsutils, utf8proc, nspsl, nsgif, nsbmp)
#   3. make TARGET=vita          -> nsvita.elf
#   4. make package-vita         -> VitaBrowser.vpk, with testpages/pages/
#
# Each flag is load-bearing:
#
#   HOST=arm-vita-eabi          selects the cross compiler in the NetSurf
#                               buildsystem (it runs $(HOST)-gcc from PATH).
#   GCC14 demotions             vitaSDK ships GCC 15, which makes six former
#                               warnings errors by default. The host build is
#                               GCC 11, where they are warnings, and that is
#                               the build every finding so far was verified
#                               on. Demoting exactly those six keeps the
#                               cross build on the same language rules. Every
#                               site they fire on is recorded in
#                               docs/phase-0/09-vita-frontend.md §3 with why
#                               it is ABI-safe.
#   WITH_EXPAT_BINDING=no       libdom's XML binding is only for SVG / XML
#                               documents, which the Vita build leaves off.
#   -I compat ... decls.h       the same shim headers as the host build.
#
# Needs vdpm packages: libvita2d (pulls freetype, libpng, libjpeg-turbo,
# zlib, bzip2) and libpcre2. Install without sudo:
#   VDPM_NONINTERACTIVE=1 vdpm install libvita2d libpcre2
#
# Usage: WORK=<WORK>/vitabrowser-work VITASDK=~/vitasdk tools/build-vita.sh
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
export VITASDK="${VITASDK:-$HOME/vitasdk}"
export PATH="$VITASDK/bin:$PATH"
UP="$WORK/applytest/upstream"
VP="${VITA_PREFIX:-$WORK/vita-prefix}"
LIBS="libwapcaplet libparserutils libhubbub libcss libdom"
SUPPORT="libnsutils libutf8proc libnspsl libnsgif libnsbmp"
GCC14="-Wno-error=implicit-function-declaration \
-Wno-error=incompatible-pointer-types -Wno-error=int-conversion \
-Wno-error=implicit-int -Wno-error=return-mismatch \
-Wno-error=declaration-missing-parameter-type"

[ -x "$VITASDK/bin/arm-vita-eabi-gcc" ] || { echo "no vitaSDK at $VITASDK"; exit 2; }
[ -f "$VITASDK/arm-vita-eabi/include/vita2d.h" ] || \
	{ echo "no libvita2d: VDPM_NONINTERACTIVE=1 vdpm install libvita2d libpcre2"; exit 2; }
[ -f "$VITASDK/arm-vita-eabi/include/pcre2posix.h" ] || \
	{ echo "no libpcre2: VDPM_NONINTERACTIVE=1 vdpm install libpcre2"; exit 2; }
[ -f "$UP/netsurf/frontends/vita/main.c" ] || \
	{ echo "no patched tree at $UP -- run tools/build-patched.sh"; exit 2; }

echo "== buildsystem -> $VP =="
rm -rf "$VP"
( cd "$WORK/buildsystem" && make install PREFIX="$VP" >/dev/null 2>&1 )

echo "== engine libraries (arm-vita-eabi) =="
export CFLAGS="-I$ROOT/compat -include macsurf_lib_decls.h $GCC14"
for l in $LIBS; do
	( cd "$UP/$l" && make install HOST=arm-vita-eabi PREFIX="$VP" \
	    PKG_CONFIG_PATH="$VP/lib/pkgconfig" WARNFLAGS="-Wall" \
	    WITH_EXPAT_BINDING=no > "$WORK/applytest/vita-build-$l.log" 2>&1 ) \
	  && echo "  $l ok" || { echo "  $l FAILED"; \
	     grep -m3 'error' "$WORK/applytest/vita-build-$l.log"; exit 1; }
done

echo "== support libraries (arm-vita-eabi) =="
export CFLAGS="$GCC14"
for l in $SUPPORT; do
	( cd "$WORK/upstream/$l" && make install HOST=arm-vita-eabi PREFIX="$VP" \
	    PKG_CONFIG_PATH="$VP/lib/pkgconfig" \
	    > "$WORK/applytest/vita-build-$l.log" 2>&1 ) \
	  && echo "  $l ok" || { echo "  $l FAILED"; \
	     grep -m3 'error' "$WORK/applytest/vita-build-$l.log"; exit 1; }
done

echo "== netsurf TARGET=vita =="
export CFLAGS="-I$VP/include/libutf8proc -I$ROOT/compat \
-include macsurf_core_decls.h -Wno-error=unused-variable -Wno-error=comment \
-Wno-error=nested-externs -Wno-error=redundant-decls \
-Wno-error=missing-prototypes $GCC14 -DVITABROWSER_ENGINE_TRACE"
EXTRA=""
for f in "$ROOT"/testpages/pages/*; do
	EXTRA="$EXTRA $f=testpages/$(basename "$f")"
done
( cd "$UP/netsurf" && rm -f nsvita.elf VitaBrowser.vpk && \
  make TARGET=vita VITA_PREFIX="$VP" -j4 > "$WORK/applytest/vita-build-netsurf.log" 2>&1 && \
  make TARGET=vita VITA_PREFIX="$VP" package-vita VITA_EXTRA_FILES="$EXTRA" \
    >> "$WORK/applytest/vita-build-netsurf.log" 2>&1 ) \
  && echo "  nsvita.elf + VitaBrowser.vpk ok" \
  || { echo "  netsurf FAILED"; \
       grep -oE '(error: |undefined reference to )[^[]*' \
         "$WORK/applytest/vita-build-netsurf.log" | sort -u | head -8; exit 1; }

"$VITASDK/bin/arm-vita-eabi-readelf" -h "$UP/netsurf/nsvita.elf" | grep -E 'Class|Machine'
ls -la "$UP/netsurf/nsvita.elf" "$UP/netsurf/VitaBrowser.vpk"
