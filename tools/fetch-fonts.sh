#!/bin/sh
# Fetch the fonts the Vita frontend draws and measures text with.
#
# Hardware run 3 (docs/phase-0/10-hardware-test-plan.md) showed the Vita's
# system PGF font falling short: glyph-atlas marks at scaled sizes,
# Greek/Cyrillic drawn as full-width glyphs from the Japanese font, missing
# Hangul and simplified Chinese. frontends/vita/text.c renders with FreeType
# instead, from this chain (checked with FreeType's FT_Get_Char_Index):
#
#   DejaVu 2.37 (Sans/Serif/Mono, real bold + italic faces)
#       Latin, Greek incl. accents, Cyrillic, symbols   Bitstream Vera licence
#   DroidSansFallbackFull (AOSP)  kana, kanji, simplified/traditional Hanzi
#                                                       Apache 2.0
#   NanumGothic (google/fonts)    Hangul                SIL OFL 1.1
#
# Every source is pinned (a release, or a commit) and checked against its
# SHA256, so a moved branch or a corrupted download fails here, not on the
# Vita. The fonts are third-party binaries (~11 MB), so they are fetched
# rather than committed; the licence texts go into the VPK beside them.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/fetch-fonts.sh
#        (writes $WORK/fonts; re-running skips what is already verified)
set -e
WORK="${WORK:-$HOME/vitabrowser-work}"
OUT="$WORK/fonts"
DL="$OUT/.download"
AOSP=3de09838fb0996bb4b420630800ad34e828fd1b6
GFONTS=e44c4b011a820c2cbe2fd2cfa8052037d7edb571
mkdir -p "$DL"

# fetch URL FILE SHA256
fetch() {
	if [ -f "$DL/$2" ] && echo "$3  $DL/$2" | sha256sum -c --status; then
		return 0
	fi
	curl -sSfL -o "$DL/$2" "$1"
	echo "$3  $DL/$2" | sha256sum -c --status || {
		echo "  CHECKSUM MISMATCH: $2 from $1"; rm -f "$DL/$2"; exit 1; }
	echo "  fetched $2"
}

echo "== fonts -> $OUT =="
fetch "https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.tar.bz2" \
	dejavu-fonts-ttf-2.37.tar.bz2 \
	fa9ca4d13871dd122f61258a80d01751d603b4d3ee14095d65453b4e846e17d7
fetch "https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/$AOSP/data/fonts/DroidSansFallbackFull.ttf" \
	DroidSansFallbackFull.ttf \
	acb6440a713d880a13a21b468ba7cd43f5a2b2934972e51be791c880730777b8
fetch "https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/$AOSP/data/fonts/NOTICE" \
	NOTICE-aosp-fonts \
	38751245389e1e23f73e6f5384b5cbe7fa972cc4410c5adc9c04b082a0b9561a
fetch "https://raw.githubusercontent.com/google/fonts/$GFONTS/ofl/nanumgothic/NanumGothic-Regular.ttf" \
	NanumGothic-Regular.ttf \
	76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31
fetch "https://raw.githubusercontent.com/google/fonts/$GFONTS/ofl/nanumgothic/OFL.txt" \
	OFL-nanum.txt \
	eeacf16032901d0ed0456876ec77b8f0fda6b3fecec7d972f8543eb602e6c30f

# The twelve DejaVu faces text.c maps generic families and styles onto.
tar -xjf "$DL/dejavu-fonts-ttf-2.37.tar.bz2" -C "$DL"
for f in DejaVuSans DejaVuSans-Bold DejaVuSans-Oblique DejaVuSans-BoldOblique \
	 DejaVuSerif DejaVuSerif-Bold DejaVuSerif-Italic DejaVuSerif-BoldItalic \
	 DejaVuSansMono DejaVuSansMono-Bold DejaVuSansMono-Oblique \
	 DejaVuSansMono-BoldOblique; do
	cp "$DL/dejavu-fonts-ttf-2.37/ttf/$f.ttf" "$OUT/"
done
cp "$DL/dejavu-fonts-ttf-2.37/LICENSE" "$OUT/LICENSE-DejaVu.txt"
cp "$DL/DroidSansFallbackFull.ttf" "$DL/NanumGothic-Regular.ttf" "$OUT/"
cp "$DL/NOTICE-aosp-fonts" "$OUT/LICENSE-DroidSansFallback.txt"
cp "$DL/OFL-nanum.txt" "$OUT/LICENSE-NanumGothic.txt"
ls "$OUT" | grep -c . | sed 's/^/  files: /'
du -sh --exclude=.download "$OUT" | cut -f1 | sed 's/^/  size: /'
