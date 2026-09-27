#!/bin/sh
# Fetch the CA bundle the Vita build verifies HTTPS servers against.
#
# vitaSDK's libcurl defaults to the firmware's own list
# (vs0:data/external/cert/CA_LIST.cer). On firmware 3.65 that list is from
# 2017 and misses roots much of the web now chains to. The frontend instead
# points NetSurf's ca_bundle option at app0:/res/ca-bundle.pem: Mozilla's
# root store as extracted by the curl project (https://curl.se/docs/caextract.html),
# pinned to a dated release and checked against its SHA256.
#
# The certificate data is Mozilla's, under MPL 2.0; the file's own header
# says so and it is bundled unmodified.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/fetch-certs.sh   (writes $WORK/certs)
set -e
WORK="${WORK:-$HOME/vitabrowser-work}"
OUT="$WORK/certs"
DATE=2026-08-13
SHA=f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9
F="$OUT/ca-bundle.pem"
mkdir -p "$OUT"
if [ -f "$F" ] && echo "$SHA  $F" | sha256sum -c --status; then
	echo "== CA bundle (Mozilla, $DATE): $F =="
	exit 0
fi
# CA_BUNDLE_LOCAL=/etc/ssl/certs/ca-certificates.crt stands in for the
# pinned file on a machine that cannot reach curl.se (a sandboxed CI or
# cloud runner). Simulator runs only: the local test pages use their own
# test CA, but live-site HTTPS then verifies against the host's roots, not
# the Vita's -- never package a VPK built this way.
if [ -n "${CA_BUNDLE_LOCAL:-}" ]; then
	cp "$CA_BUNDLE_LOCAL" "$F"
	echo "== CA bundle: $CA_BUNDLE_LOCAL (NOT the pinned Mozilla $DATE file) =="
	exit 0
fi
curl -sSfL -o "$F.tmp" "https://curl.se/ca/cacert-$DATE.pem"
echo "$SHA  $F.tmp" | sha256sum -c --status || \
	{ echo "  CHECKSUM MISMATCH: cacert-$DATE.pem"; rm -f "$F.tmp"; exit 1; }
mv "$F.tmp" "$F"
echo "== CA bundle (Mozilla, $DATE): $(grep -c 'BEGIN CERTIFICATE' "$F") roots -> $F =="
