#!/bin/sh
# Build an AddressSanitizer copy of the host simulator (nsvita-sim) from the
# current applytest tree, without touching applytest itself.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/build-asan-sim.sh \
#            [--libs] [--js] [--net] [--freetype] [--support] [--all] <dest-dir>
#        (after tools/run-vita-sim.sh: needs its overlay + libvitasim.a)
# Result: <dest-dir>/netsurf/nsvita-sim.
#   default    instrumented netsurf code only (every library comes from the
#              uninstrumented prefixes the gate uses).
#   --libs     also libwapcaplet, libparserutils (+ the sim's
#              WITHOUT_ICONV_FILTER overlay), libhubbub, libcss and libdom,
#              rebuilt with ASan from applytest's staged (patched) trees into
#              <dest-dir>/prefix and <dest-dir>/overlay (unit 399).
#   --js       also QuickJS-ng and wasm3, compiled as tools/build-quickjs.sh
#              does (same sources in $WORK/quickjs and $WORK/wasm3, same flags)
#              plus ASan, into <dest-dir>/quickjs (unit 400). The instrumented
#              interpreter runs ~3x slower, so the per-script deadline
#              (MACSURF_JS_TIMEOUT_MS, 8000 ms, #ifndef in macsurf_qjs.c) is
#              raised to ASAN_JS_TIMEOUT_MS (default 32000) in this build only:
#              at 8000, scripts on rte/wpblog/wikipedia were cut off by
#              "DEADLINE hit" and their tails went unchecked.
#   --net      also mbedTLS and curl, built as tools/build-host-curl.sh does
#              (its cached, checksummed tarballs in $WORK/src; same config and
#              cmake options) plus ASan, into <dest-dir>/host-curl (unit 401).
#   --freetype also FreeType, as tools/build-host-freetype.sh does, plus ASan,
#              into <dest-dir>/host-freetype (unit 401).
#   --support  also libnsutils, libutf8proc, libnsgif, libnsbmp, libnspsl and
#              the staged (patched) libsvgtiny, as tools/build-patched.sh
#              builds them, plus ASan, into <dest-dir>/prefix (unit 401).
#   --all      all of the above.
# Not covered by any flag: the system shared libraries the sim loads
# (libjpeg, libpng, libwebp, zlib, expat, pcre2).
# Drive it with tools/scorecard/asan_sweep.py and tools/asan-autotest.sh.
# Patch 395/396 entry, doc 10.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
LIBS_TOO=; JS_TOO=; NET_TOO=; FT_TOO=; SUP_TOO=
while :; do case "$1" in
	--libs) LIBS_TOO=1; shift ;;
	--js) JS_TOO=1; shift ;;
	--net) NET_TOO=1; shift ;;
	--freetype) FT_TOO=1; shift ;;
	--support) SUP_TOO=1; shift ;;
	--all) LIBS_TOO=1; JS_TOO=1; NET_TOO=1; FT_TOO=1; SUP_TOO=1; shift ;;
	-*) echo "unknown option $1"; exit 2 ;;
	*) break ;;
esac; done
DEST="${1:?usage: build-asan-sim.sh [--libs] [--js] [--net] [--freetype] [--support] [--all] <dest-dir>}"
P="$WORK/applytest/prefix"; OUT="$WORK/vita-sim"; OV="$OUT/overlay"
CURLP="$WORK/host-curl"; FTP="$WORK/host-freetype"; QJS="$WORK/host-quickjs"
[ -f "$OUT/libvitasim.a" ] || { echo "no $OUT/libvitasim.a: run tools/run-vita-sim.sh first"; exit 1; }
mkdir -p "$DEST"; DEST=$(cd "$DEST" && pwd)
ASAN="-fsanitize=address -fno-omit-frame-pointer -g"
# the libraries' host-side generators (libcss's, libhubbub's) are built with
# the same flags and run during the build: no leak report on their exit
export ASAN_OPTIONS=detect_leaks=0
rm -rf "$DEST/src"; mkdir -p "$DEST/src"

instrumented() {	# $1 = archive: at least one ASan check in it
	nm "$1" 2>/dev/null | grep -q __asan_report || { echo "  $1: not instrumented"; exit 1; }
}

if [ -n "$LIBS_TOO$SUP_TOO" ]; then
	# a copy of applytest's prefix; the rebuilt libraries replace theirs
	AP="$DEST/prefix"
	rm -rf "$AP"
	cp -a "$P" "$AP"
	# the copied .pc files still name applytest's prefix
	sed -i "s|$P|$AP|g" "$AP"/lib/pkgconfig/*.pc
fi

if [ -n "$LIBS_TOO" ]; then
	AOV="$DEST/overlay"
	rm -rf "$AOV"
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
		instrumented "$AP/lib/$l.a"
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
	instrumented "$AOV/lib/libparserutils.a"
	echo "  parserutils overlay (ASan) ok"
	OV="$AOV"
fi

if [ -n "$SUP_TOO" ]; then
	# tools/build-patched.sh's support build: CFLAGS without the compat
	# header, pristine trees except libsvgtiny (staged, patch 346)
	for l in libnsutils libutf8proc libnsgif libnsbmp libnspsl libsvgtiny; do
		if [ "$l" = libsvgtiny ]; then src="$WORK/applytest/upstream/$l"
		else src="$WORK/upstream/$l"; fi
		cp -r "$src" "$DEST/src/$l"
		rm -rf "$DEST/src/$l"/build-*
		( cd "$DEST/src/$l" && \
		  CFLAGS="$ASAN" LDFLAGS="-fsanitize=address" \
		  PKG_CONFIG_PATH="$AP/lib/pkgconfig" PATH="$AP/bin:$PATH" \
		  make install PREFIX="$AP" > "$DEST/build-$l.log" 2>&1 ) \
		  && echo "  $l (ASan) ok" || { echo "  $l FAILED"; \
		     grep -m3 -E 'error|undefined' "$DEST/build-$l.log"; exit 1; }
		instrumented "$AP/lib/$l.a"
	done
fi

if [ -n "$LIBS_TOO$SUP_TOO" ]; then
	P="$AP"
fi

if [ -n "$NET_TOO" ]; then
	# tools/build-host-curl.sh, from its cached tarballs, plus ASan
	MBED=3.6.5; CURL=8.22.0; CURLP="$DEST/host-curl"
	for t in "mbedtls-$MBED.tar.bz2" "curl-$CURL.tar.xz"; do
		[ -f "$WORK/src/$t" ] || { echo "no $WORK/src/$t: run tools/build-host-curl.sh first"; exit 1; }
	done
	grep -q "\"$CURL\"" "$WORK/host-curl/include/curl/curlver.h" || \
		{ echo "host-curl is not curl $CURL: update the versions here to match build-host-curl.sh"; exit 1; }
	rm -rf "$CURLP"
	tar -xjf "$WORK/src/mbedtls-$MBED.tar.bz2" -C "$DEST/src"
	( cd "$DEST/src/mbedtls-$MBED" && \
	  python3 scripts/config.py set MBEDTLS_THREADING_C && \
	  python3 scripts/config.py set MBEDTLS_THREADING_PTHREAD && \
	  mkdir build && cd build && \
	  cmake .. -DCMAKE_INSTALL_PREFIX="$CURLP" -DCMAKE_BUILD_TYPE=Release \
	    -DCMAKE_C_FLAGS="$ASAN" \
	    -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DMBEDTLS_FATAL_WARNINGS=OFF \
	    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON && \
	  make -j4 && make install ) > "$DEST/build-mbedtls.log" 2>&1 \
	  || { echo "  mbedTLS FAILED (see $DEST/build-mbedtls.log)"; exit 1; }
	for l in libmbedtls libmbedx509 libmbedcrypto; do instrumented "$CURLP/lib/$l.a"; done
	echo "  mbedTLS $MBED (ASan) ok"
	tar -xJf "$WORK/src/curl-$CURL.tar.xz" -C "$DEST/src"
	( cd "$DEST/src/curl-$CURL" && mkdir build && cd build && \
	  cmake .. -DCMAKE_INSTALL_PREFIX="$CURLP" -DCMAKE_BUILD_TYPE=Release \
	    -DCMAKE_C_FLAGS="$ASAN" \
	    -DCMAKE_PREFIX_PATH="$CURLP" -DMBEDTLS_INCLUDE_DIR="$CURLP/include" \
	    -DBUILD_CURL_EXE=OFF -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
	    -DENABLE_IPV6=OFF -DENABLE_THREADED_RESOLVER=OFF -DCURL_USE_LIBPSL=OFF \
	    -DCURL_ZSTD=OFF -DCURL_BROTLI=OFF -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF \
	    -DCURL_USE_LIBSSH2=OFF -DCURL_USE_GSSAPI=OFF -DCURL_DISABLE_LDAP=ON \
	    -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF \
	    -DCURL_USE_MBEDTLS=ON -DCURL_USE_OPENSSL=OFF \
	    -DCMAKE_DISABLE_FIND_PACKAGE_Threads=ON && \
	  make -j4 && make install ) > "$DEST/build-curl.log" 2>&1 \
	  || { echo "  curl FAILED (see $DEST/build-curl.log)"; exit 1; }
	instrumented "$CURLP/lib/libcurl.a"
	echo "  curl $CURL (ASan) ok"
fi

if [ -n "$FT_TOO" ]; then
	# tools/build-host-freetype.sh, from its cached tarball, plus ASan
	FTV=2.14.3; FTP="$DEST/host-freetype"
	[ -f "$WORK/src/freetype-$FTV.tar.xz" ] || { echo "no $WORK/src/freetype-$FTV.tar.xz: run tools/build-host-freetype.sh first"; exit 1; }
	rm -rf "$FTP"
	tar -xJf "$WORK/src/freetype-$FTV.tar.xz" -C "$DEST/src"
	( cd "$DEST/src/freetype-$FTV" && \
	  CFLAGS="-O2 $ASAN" LDFLAGS="-fsanitize=address" \
	  ./configure --prefix="$FTP" --enable-static --disable-shared \
	    --without-harfbuzz --without-brotli --without-png --with-zlib=yes \
	    --with-bzip2=no && make -j4 && make install ) > "$DEST/build-freetype.log" 2>&1 \
	  || { echo "  FreeType FAILED (see $DEST/build-freetype.log)"; exit 1; }
	instrumented "$FTP/lib/libfreetype.a"
	echo "  FreeType $FTV (ASan) ok"
fi

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
	for l in libquickjs libm3; do instrumented "$QJS/lib/$l.a"; done
	echo "  quickjs + wasm3 (ASan) ok"
fi

rm -rf "$DEST/netsurf"
cp -a "$WORK/applytest/upstream/netsurf" "$DEST/netsurf"
rm -rf "$DEST/netsurf/build/"*vita* "$DEST/netsurf/nsvita-sim"
export PKG_CONFIG_PATH="$CURLP/lib/pkgconfig:$FTP/lib/pkgconfig:$OV/lib/pkgconfig:$P/lib/pkgconfig"
# run-vita-sim.sh's flags, plus ASan; GCC's -O2 stringop/array-bounds
# warnings fire under ASan instrumentation, so they are not errors here.
export CFLAGS="-I$P/include/libutf8proc -I$ROOT/compat \
-include macsurf_core_decls.h -Wno-error=unused-variable -Wno-error=comment -Wno-error=nested-externs -Wno-error=redundant-decls -Wno-error=missing-prototypes -Wno-error=implicit-function-declaration -Wno-error=int-conversion -DVITABROWSER_ENGINE_TRACE \
$ASAN ${JS_TOO:+-DMACSURF_JS_TIMEOUT_MS=${ASAN_JS_TIMEOUT_MS:-32000}} -Wno-error=stringop-overread -Wno-error=array-bounds -Wno-error=stringop-overflow -Wno-error=maybe-uninitialized"
# -L order: the overlay first (run-vita-sim.sh: pkgconf would otherwise pick
# the prefix's iconv libparserutils), then the instrumented prefixes ahead
# of anything pkg-config adds.
export LDFLAGS="-L$OV/lib -L$P/lib -L$CURLP/lib -L$FTP/lib -fsanitize=address"
cd "$DEST/netsurf"
make TARGET=vita VITA_HOST_SIM=YES \
	VITA_SIM_INCLUDE="$ROOT/tools/vita-stub" VITA_SIM_LIB="$OUT/libvitasim.a" \
	VITA_SIM_QUICKJS="$QJS" -j4 > "$DEST/asan-build.log" 2>&1 \
  || { grep -m8 -E 'error|undefined' "$DEST/asan-build.log"; exit 1; }
echo "ASan sim: $DEST/netsurf/nsvita-sim${LIBS_TOO:+ +engine libraries}${SUP_TOO:+ +support libraries}${NET_TOO:+ +curl/mbedTLS}${FT_TOO:+ +FreeType}${JS_TOO:+ +QuickJS/wasm3}"
