#!/bin/sh
# Build an AddressSanitizer copy of the host simulator (nsvita-sim) from the
# current applytest tree, without touching applytest itself.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/build-asan-sim.sh [--libs] [--js] <dest-dir>
#        (after tools/run-vita-sim.sh: needs its overlay + libvitasim.a)
# Result: <dest-dir>/netsurf/nsvita-sim.
#   default  instrumented netsurf code only (the engine libraries come from
#            applytest's uninstrumented prefix).
#   --libs   also libwapcaplet, libparserutils (+ the sim's WITHOUT_ICONV_FILTER
#            overlay), libhubbub, libcss and libdom, rebuilt with ASan from
#            applytest's staged (patched) trees into <dest-dir>/prefix and
#            <dest-dir>/overlay (unit 399). QuickJS, curl, mbedTLS, FreeType
#            and the support libraries stay uninstrumented.
#   --js     also QuickJS-ng and wasm3, compiled as tools/build-quickjs.sh
#            does (same sources in $WORK/quickjs and $WORK/wasm3, same flags)
#            plus ASan, into <dest-dir>/quickjs (unit 400). The instrumented
#            interpreter runs ~3x slower, so the per-script deadline
#            (MACSURF_JS_TIMEOUT_MS, 8000 ms, #ifndef in macsurf_qjs.c) is
#            raised to ASAN_JS_TIMEOUT_MS (default 32000) in this build only:
#            at 8000, scripts on rte/wpblog/wikipedia were cut off by
#            "DEADLINE hit" and their tails went unchecked.
# Drive it with tools/scorecard/asan_sweep.py and tools/asan-autotest.sh.
# Patch 395/396 entry, doc 10.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
LIBS_TOO=; JS_TOO=
while :; do case "$1" in
	--libs) LIBS_TOO=1; shift ;;
	--js) JS_TOO=1; shift ;;
	*) break ;;
esac; done
DEST="${1:?usage: build-asan-sim.sh [--libs] [--js] <dest-dir>}"
P="$WORK/applytest/prefix"; OUT="$WORK/vita-sim"; OV="$OUT/overlay"
[ -f "$OUT/libvitasim.a" ] || { echo "no $OUT/libvitasim.a: run tools/run-vita-sim.sh first"; exit 1; }
mkdir -p "$DEST"; DEST=$(cd "$DEST" && pwd)
ASAN="-fsanitize=address -fno-omit-frame-pointer -g"
# the libraries' host-side generators (libcss's, libhubbub's) are built with
# the same flags and run during the build: no leak report on their exit
export ASAN_OPTIONS=detect_leaks=0

if [ -n "$LIBS_TOO" ]; then
	AP="$DEST/prefix"; AOV="$DEST/overlay"
	rm -rf "$AP" "$AOV" "$DEST/src"
	cp -a "$P" "$AP"
	# the copied .pc files still name applytest's prefix
	sed -i "s|$P|$AP|g" "$AP"/lib/pkgconfig/*.pc
	mkdir -p "$DEST/src"
	for l in libwapcaplet libparserutils libhubbub libcss libdom; do
		cp -r "$WORK/applytest/upstream/$l" "$DEST/src/$l"
		rm -rf "$DEST/src/$l"/build-*
		( cd "$DEST/src/$l" && \
		  CFLAGS="-I$ROOT/compat -include macsurf_lib_decls.h $ASAN" \
		  LDFLAGS="-fsanitize=address" \
		  PKG_CONFIG_PATH="$AP/lib/pkgconfig" PATH="$AP/bin:$PATH" \
		  make install PREFIX="$AP" WARNFLAGS="-Wall" \
		    > "$DEST/build-$l.log" 2>&1 ) \
		  && echo "  $l (ASan) ok" || { echo "  $l FAILED"; \
		     grep -m3 -E 'error|undefined' "$DEST/build-$l.log"; exit 1; }
		nm "$AP/lib/$l.a" | grep -q __asan_report || { echo "  $l: not instrumented"; exit 1; }
	done
	# the sim's libparserutils, as run-vita-sim.sh builds it
	cp -r "$WORK/applytest/upstream/libparserutils" "$DEST/src/parserutils-overlay"
	rm -rf "$DEST/src/parserutils-overlay"/build-*
	( cd "$DEST/src/parserutils-overlay" && \
	  CFLAGS="-I$ROOT/compat -include macsurf_lib_decls.h -DWITHOUT_ICONV_FILTER $ASAN" \
	  PKG_CONFIG_PATH="$AP/lib/pkgconfig" \
	  make install PREFIX="$AOV" NSSHARED="$AP/share/netsurf-buildsystem" \
	    WARNFLAGS=-Wall > "$DEST/build-overlay.log" 2>&1 ) \
	  || { echo "  overlay FAILED"; grep -m3 error "$DEST/build-overlay.log"; exit 1; }
	if nm "$AOV/lib/libparserutils.a" | grep -q " U iconv_open"; then
		echo "  overlay still uses iconv"; exit 1
	fi
	echo "  parserutils overlay (ASan) ok"
	P="$AP"; OV="$AOV"
fi

QJS="$WORK/host-quickjs"
if [ -n "$JS_TOO" ]; then
	# tools/build-quickjs.sh's build() and build_m3(), with $ASAN added
	Q="$WORK/quickjs"; W="$WORK/wasm3/source"; QJS="$DEST/quickjs"
	[ -f "$Q/quickjs.c" ] && [ -f "$W/m3_core.c" ] || { echo "no $Q / $W: run tools/build-quickjs.sh host first"; exit 1; }
	rm -rf "$QJS"; mkdir -p "$QJS/obj" "$QJS/lib" "$QJS/include/quickjs" "$QJS/include/wasm3"
	for f in quickjs libregexp libunicode dtoa; do
		gcc -c -O2 -g -D_GNU_SOURCE -include pthread.h $ASAN -I"$Q" \
			"$Q/$f.c" -o "$QJS/obj/$f.o" 2> "$QJS/obj/$f.log" || \
			{ echo "  quickjs $f.c FAILED"; grep -m5 error "$QJS/obj/$f.log"; exit 1; }
	done
	ar rcs "$QJS/lib/libquickjs.a" "$QJS"/obj/quickjs.o "$QJS"/obj/libregexp.o \
		"$QJS"/obj/libunicode.o "$QJS"/obj/dtoa.o
	cp "$Q/quickjs.h" "$QJS/include/quickjs/"
	for f in m3_bind m3_code m3_compile m3_core m3_emit m3_env m3_exec m3_function \
		 m3_info m3_module m3_optimize m3_parse; do
		gcc -c -O3 -g -std=gnu11 -fwrapv -Wno-unused-function $ASAN -I"$W" \
			"$W/$f.c" -o "$QJS/obj/$f.o" 2> "$QJS/obj/$f.log" || \
			{ echo "  wasm3 $f.c FAILED"; grep -m5 error "$QJS/obj/$f.log"; exit 1; }
	done
	ar rcs "$QJS/lib/libm3.a" "$QJS"/obj/m3_*.o
	cp "$W"/*.h "$QJS/include/wasm3/"
	for l in libquickjs libm3; do
		nm "$QJS/lib/$l.a" | grep -q __asan_report || { echo "  $l: not instrumented"; exit 1; }
	done
	echo "  quickjs + wasm3 (ASan) ok"
fi

rm -rf "$DEST/netsurf"
cp -a "$WORK/applytest/upstream/netsurf" "$DEST/netsurf"
rm -rf "$DEST/netsurf/build/"*vita* "$DEST/netsurf/nsvita-sim"
export PKG_CONFIG_PATH="$WORK/host-curl/lib/pkgconfig:$WORK/host-freetype/lib/pkgconfig:$OV/lib/pkgconfig:$P/lib/pkgconfig"
# run-vita-sim.sh's flags, plus ASan; GCC's -O2 stringop/array-bounds
# warnings fire under ASan instrumentation, so they are not errors here.
export CFLAGS="-I$P/include/libutf8proc -I$ROOT/compat \
-include macsurf_core_decls.h -Wno-error=unused-variable -Wno-error=comment -Wno-error=nested-externs -Wno-error=redundant-decls -Wno-error=missing-prototypes -Wno-error=implicit-function-declaration -Wno-error=int-conversion -DVITABROWSER_ENGINE_TRACE \
$ASAN ${JS_TOO:+-DMACSURF_JS_TIMEOUT_MS=${ASAN_JS_TIMEOUT_MS:-32000}} -Wno-error=stringop-overread -Wno-error=array-bounds -Wno-error=stringop-overflow -Wno-error=maybe-uninitialized"
export LDFLAGS="-L$OV/lib -L$P/lib -fsanitize=address"
cd "$DEST/netsurf"
make TARGET=vita VITA_HOST_SIM=YES \
	VITA_SIM_INCLUDE="$ROOT/tools/vita-stub" VITA_SIM_LIB="$OUT/libvitasim.a" \
	VITA_SIM_QUICKJS="$QJS" -j4 > "$DEST/asan-build.log" 2>&1 \
  || { grep -m8 -E 'error|undefined' "$DEST/asan-build.log"; exit 1; }
echo "ASan sim: $DEST/netsurf/nsvita-sim${LIBS_TOO:+ +engine libraries}${JS_TOO:+ +QuickJS/wasm3}"
