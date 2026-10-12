#!/bin/sh
# Fetch the WebAssembly interpreter: wasm3 0.5.0 (MIT, portable C; the
# version docs/wasm-hcaptcha-measurement.md measured hCaptcha's module with).
# The release tarball is pinned by sha256; patches/wasm3/*.patch are applied
# (each explained in its header). Only source/ is kept, with the licence.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/fetch-wasm3.sh   (writes $WORK/wasm3)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
VER=0.5.0
SHA=b778dd72ee2251f4fe9e2666ee3fe1c26f06f517c3ffce572416db067546536c
URL=https://github.com/wasm3/wasm3/archive/refs/tags/v$VER.tar.gz
STAMP="$VER $(cat "$ROOT"/patches/wasm3/*.patch | sha256sum | cut -c1-12)"
OUT="$WORK/wasm3"
TGZ="$WORK/wasm3-dl/wasm3-$VER.tar.gz"
if [ -f "$OUT/.rev" ] && [ "$(cat "$OUT/.rev")" = "$STAMP" ]; then
	echo "== wasm3 $VER: $OUT =="
	exit 0
fi
mkdir -p "$WORK/wasm3-dl"
if [ ! -f "$TGZ" ] || [ "$(sha256sum "$TGZ" | cut -d' ' -f1)" != "$SHA" ]; then
	curl -sSL -o "$TGZ.part" "$URL"
	[ "$(sha256sum "$TGZ.part" | cut -d' ' -f1)" = "$SHA" ] || \
		{ echo "  $URL: sha256 mismatch"; rm -f "$TGZ.part"; exit 1; }
	mv "$TGZ.part" "$TGZ"
fi
rm -rf "$OUT" "$OUT.tmp"; mkdir -p "$OUT.tmp"
tar xzf "$TGZ" -C "$OUT.tmp" --strip-components=1
mkdir -p "$OUT"
mv "$OUT.tmp/source" "$OUT/source"
cp "$OUT.tmp/LICENSE" "$OUT/LICENSE"
rm -rf "$OUT.tmp"
for p in "$ROOT"/patches/wasm3/*.patch; do
	patch -s -p1 -d "$OUT" < "$p" || { echo "  $p does not apply"; exit 1; }
	echo "  applied $(basename "$p")"
done
echo "$STAMP" > "$OUT/.rev"
echo "== wasm3 $VER -> $OUT =="
