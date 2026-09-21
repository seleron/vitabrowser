/*
 * macsurf_lib_decls.h -- VitaBrowser compatibility shim, libraries only.
 *
 * Force-included into the five NetSurf core libraries (see
 * tools/build-patched.sh). MacSurf's library patches call the trace function
 * after declaring it with a nested `extern`; the splitter strips those,
 * because upstream builds the libraries with -Wnested-externs -Werror. That
 * leaves no declaration at all, so this header supplies one.
 *
 * Deliberately NOT part of macsurf_debug.h: netsurf's core already declares
 * the same symbol in content_protected.h and several .c files, and netsurf
 * includes macsurf_debug.h by name, so a declaration there would trip
 * -Werror=redundant-decls.
 */
#ifndef VITABROWSER_MACSURF_LIB_DECLS_H
#define VITABROWSER_MACSURF_LIB_DECLS_H

#include <stdarg.h>

/* Nothing declared here any more: the splitter no longer strips MacSurf's
 * own nested externs, so every caller carries its own declaration. The
 * header is kept as the force-include anchor and for <stdarg.h>. */

#endif /* VITABROWSER_MACSURF_LIB_DECLS_H */
