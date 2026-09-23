#!/bin/sh
# Build the Vita's TLS stack for the host: mbedTLS 3.6.5 and libcurl 8.22.0,
# the versions and options of vitaSDK's `mbedtls` and `curl-mbedtls`
# packages (github.com/vitasdk/packages: mbedtls/VITABUILD,
# curl-mbedtls/VITABUILD). The host simulator links them, so certificate
# parsing, verification and TLS negotiation in a simulator run are the code
# the Vita runs, not the host's libcurl-on-OpenSSL.
#
# vitaSDK's mbedtls.patch only adds __vita__ branches (entropy from
# getentropy() -> sceKernelGetRandomNumber, non-blocking sockets), so the
# host build is the pristine source with the same config.py settings.
# Tarball checksums are the ones pinned in those VITABUILDs.
#
# Userspace only: installs into $WORK/host-curl.
# Usage: WORK=<WORK>/vitabrowser-work tools/build-host-curl.sh   (no-op once built)
set -e
WORK="${WORK:-$HOME/vitabrowser-work}"
PREFIX="$WORK/host-curl"
SRC="$WORK/src"
MBED=3.6.5
MBED_SHA=4a11f1777bb95bf4ad96721cac945a26e04bf19f57d905f241fe77ebeddf46d8
CURL=8.22.0
CURL_SHA=f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7

if [ -f "$PREFIX/lib/libcurl.a" ] && [ -f "$PREFIX/lib/libmbedtls.a" ] && \
   grep -q "\"$CURL\"" "$PREFIX/include/curl/curlver.h" 2>/dev/null; then
	echo "== host curl $CURL + mbedTLS $MBED: installed in $PREFIX =="
	exit 0
fi
mkdir -p "$SRC"

# get URL FILE SHA256
get() {
	if ! { [ -f "$SRC/$2" ] && echo "$3  $SRC/$2" | sha256sum -c --status; }; then
		curl -sSfL -o "$SRC/$2" "$1"
		echo "$3  $SRC/$2" | sha256sum -c --status || \
			{ echo "  CHECKSUM MISMATCH: $2"; rm -f "$SRC/$2"; exit 1; }
	fi
}
get "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBED/mbedtls-$MBED.tar.bz2" \
	"mbedtls-$MBED.tar.bz2" "$MBED_SHA"
get "https://github.com/curl/curl/releases/download/curl-$(echo $CURL | tr . _)/curl-$CURL.tar.xz" \
	"curl-$CURL.tar.xz" "$CURL_SHA"

LOG="$SRC/host-curl.log"
: > "$LOG"
echo "== host mbedTLS $MBED -> $PREFIX =="
rm -rf "$SRC/mbedtls-$MBED"
tar -xjf "$SRC/mbedtls-$MBED.tar.bz2" -C "$SRC"
( cd "$SRC/mbedtls-$MBED" && \
  python3 scripts/config.py set MBEDTLS_THREADING_C && \
  python3 scripts/config.py set MBEDTLS_THREADING_PTHREAD && \
  mkdir build && cd build && \
  cmake .. -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DMBEDTLS_FATAL_WARNINGS=OFF \
    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON && \
  make -j4 && make install ) >> "$LOG" 2>&1 || { echo "  FAILED (see $LOG)"; exit 1; }

echo "== host curl $CURL (mbedTLS) -> $PREFIX =="
rm -rf "$SRC/curl-$CURL"
tar -xJf "$SRC/curl-$CURL.tar.xz" -C "$SRC"
# vitaSDK's options, less the Vita-only ones (toolchain, fcntl, pipe2, the
# vs0: default CA path): no IPv6, no threaded resolver, no libpsl, no zstd.
( cd "$SRC/curl-$CURL" && mkdir build && cd build && \
  cmake .. -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$PREFIX" -DMBEDTLS_INCLUDE_DIR="$PREFIX/include" \
    -DBUILD_CURL_EXE=OFF -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DENABLE_IPV6=OFF -DENABLE_THREADED_RESOLVER=OFF -DCURL_USE_LIBPSL=OFF \
    -DCURL_ZSTD=OFF -DCURL_BROTLI=OFF -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF \
    -DCURL_USE_LIBSSH2=OFF -DCURL_USE_GSSAPI=OFF -DCURL_DISABLE_LDAP=ON \
    -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF \
    -DCURL_USE_MBEDTLS=ON -DCURL_USE_OPENSSL=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_Threads=ON && \
  make -j4 && make install ) >> "$LOG" 2>&1 || { echo "  FAILED (see $LOG)"; exit 1; }
echo "  ok"
