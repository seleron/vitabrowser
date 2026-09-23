#!/bin/sh
# Build the FreeType the Vita has (vitaSDK's libfreetype, 2.14.3) for the
# host, so the simulator and the text test rasterise and measure exactly as
# the device does. The host's own FreeType (Ubuntu 22.04: 2.11.1) is three
# releases older; hinted advances can differ between releases, and a
# one-pixel advance difference moves every later glyph on the line, so
# device-vs-simulator plot dumps would differ for reasons that are not
# bugs (docs/phase-0/10-hardware-test-plan.md §Run 6).
#
# Userspace only: installs into $WORK/host-freetype. Checksum cross-checked
# between savannah.gnu.org and sourceforge.net (the two official mirrors).
#
# Usage: WORK=<WORK>/vitabrowser-work tools/build-host-freetype.sh
#        (re-running is a no-op once installed)
set -e
WORK="${WORK:-$HOME/vitabrowser-work}"
VER=2.14.3
SHA=36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f
PREFIX="$WORK/host-freetype"
SRC="$WORK/src"

# freetype2.pc reports the libtool version; the header is the real check.
if [ -f "$PREFIX/include/freetype2/freetype/freetype.h" ] && \
   grep -q "FREETYPE_MINOR  14" "$PREFIX/include/freetype2/freetype/freetype.h" && \
   grep -q "FREETYPE_PATCH  3" "$PREFIX/include/freetype2/freetype/freetype.h"; then
	echo "== host FreeType $VER: installed in $PREFIX =="
	exit 0
fi

echo "== host FreeType $VER -> $PREFIX =="
mkdir -p "$SRC"
T="$SRC/freetype-$VER.tar.xz"
if ! { [ -f "$T" ] && echo "$SHA  $T" | sha256sum -c --status; }; then
	curl -sSfL -o "$T" "https://download.savannah.gnu.org/releases/freetype/freetype-$VER.tar.xz"
	echo "$SHA  $T" | sha256sum -c --status || { echo "  CHECKSUM MISMATCH"; rm -f "$T"; exit 1; }
fi
rm -rf "$SRC/freetype-$VER"
tar -xJf "$T" -C "$SRC"
# Static, and only what text.c uses: no HarfBuzz, Brotli (WOFF2) or PNG
# (colour bitmap fonts) -- the bundled fonts are plain TrueType.
( cd "$SRC/freetype-$VER" && \
  ./configure --prefix="$PREFIX" --enable-static --disable-shared \
    --without-harfbuzz --without-brotli --without-png --with-zlib=yes \
    --with-bzip2=no > "$SRC/freetype-$VER.log" 2>&1 && \
  make -j4 >> "$SRC/freetype-$VER.log" 2>&1 && \
  make install >> "$SRC/freetype-$VER.log" 2>&1 ) \
  || { echo "  FAILED (see $SRC/freetype-$VER.log)"; exit 1; }
echo "  ok"
