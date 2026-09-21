#!/bin/sh
# Build the MacSurf-patched engine and nsmonkey from a clean upstream tree.
#
# The recipe has enough non-obvious parts that it must live in a file rather
# than in someone's shell history. Each flag below is load-bearing:
#
#   -I compat                 the shim headers (see compat/README in the docs)
#   -include macsurf_lib_decls.h for the LIBRARIES. The splitter strips MacSurf's
#                             nested extern declarations, which in the libraries
#                             were the only declaration of the trace function --
#                             without this you get "incompatible implicit
#                             declaration of macsurf_debug_log_writef".
#   -include macsurf_core_decls.h   for NETSURF. Same reason, plus the core
#                             additions MacSurf declared only in their frontend.
#   -Wno-error=unused-variable      MacSurf's debug leftovers (`ua`, `na` in
#                             content_broadcast) are assigned and never read.
#                             Demoted, not silenced: the warnings still print.
#   -Wno-error=comment        html/form.c has a comment reading "Sets *min/*max
#                             to", and `/*` inside a comment is what -Wcomment
#                             is for. Nothing to fix in the code.
#   C_INCLUDE_PATH not CFLAGS for the buildsystem's own -Isrc to survive; a
#                             CFLAGS on the make command line replaces it.
#
# Usage: WORK=<WORK>/vitabrowser-work tools/build-patched.sh
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${WORK:-$HOME/vitabrowser-work}"
P="$WORK/applytest/prefix"
LIBS="libwapcaplet libparserutils libhubbub libcss libdom"
SUPPORT="libnsutils libutf8proc libnsgif libnsbmp libnspsl libsvgtiny nsgenbind"

# The splitter strips extern declarations for whatever compat/*.h declares, so
# the patch set is a function of the compat headers. Editing a header without
# regenerating leaves stale patches, which fail as redundant-declaration or
# undeclared-identifier errors that look like code problems. Regenerate first.
echo "== regenerating the patch stack =="
python3 "$ROOT/tools/split-patches.py" | tail -1

echo "== staging clean upstream trees =="
rm -rf "$WORK/applytest/upstream"
mkdir -p "$WORK/applytest/upstream"
for l in $LIBS netsurf; do
	cp -r "$WORK/upstream/$l" "$WORK/applytest/upstream/$l"
done
( cd "$WORK/applytest/upstream/netsurf" && rm -f nsmonkey && \
  make clean TARGET=monkey >/dev/null 2>&1 || true )

echo "== applying the stack =="
WORK="$WORK/applytest" "$ROOT/tools/apply-patches.sh" | tail -2

echo "== building libraries =="
rm -rf "$P"
export PKG_CONFIG_PATH="$P/lib/pkgconfig"
export PATH="$P/bin:$PATH"
( cd "$WORK/buildsystem" && make install PREFIX="$P" >/dev/null 2>&1 )
CFLAGS="-I$ROOT/compat -include macsurf_lib_decls.h"
export CFLAGS
for l in $LIBS; do
	( cd "$WORK/applytest/upstream/$l" && \
	  make install PREFIX="$P" WARNFLAGS="-Wall" \
	    > "$WORK/applytest/build-$l.log" 2>&1 ) \
	  && echo "  $l ok" || { echo "  $l FAILED"; \
	     grep -m2 'error:' "$WORK/applytest/build-$l.log"; exit 1; }
done

echo "== building support libraries =="
unset CFLAGS
for l in $SUPPORT; do
	( cd "$WORK/upstream/$l" && make install PREFIX="$P" >/dev/null 2>&1 ) || true
done

echo "== building netsurf + nsmonkey =="
export PREFIX="$P"
export CFLAGS="-I$P/include/libutf8proc -I$ROOT/compat \
-include macsurf_core_decls.h -Wno-error=unused-variable -Wno-error=comment"
( cd "$WORK/applytest/upstream/netsurf" && \
  make TARGET=monkey -j4 > "$WORK/applytest/build-netsurf.log" 2>&1 ) \
  && echo "  netsurf ok" \
  || { echo "  netsurf FAILED"; \
       grep -oE 'error: [^[]*' "$WORK/applytest/build-netsurf.log" \
         | sort -u | head -8; exit 1; }

ls -la "$WORK/applytest/upstream/netsurf/nsmonkey"
