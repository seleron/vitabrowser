/*
 * macsurf_debug.h -- VitaBrowser compatibility shim.
 *
 * MacSurf's engine patches call macsurf_debug_log_writef() for hardware
 * tracing. On Mac OS 9 that writes to their on-device log; the Linux+ASan
 * harness in MacSurf's own harness/ replaces it, and harness/BUILD-NOTES.md
 * section "Layer 4" lists this header as one of three stubs a port must
 * provide. This is ours.
 *
 * Two things matter here beyond compiling:
 *
 *   1. The declaration must be at file scope. MacSurf's patches declare it
 *      inline inside functions, which upstream NetSurf's -Wnested-externs
 *      -Werror rejects. Including this header first gives the symbol a proper
 *      declaration.
 *
 *   2. Logging must stay compiled-out by default. Brief section 8 item 1
 *      records MacSurf losing four debugging rounds to a silent defensive
 *      clamp, and their remedy was to log every time one fires. We want that
 *      option on the Vita -- but not the cost on every page by default.
 */
#ifndef VITABROWSER_MACSURF_DEBUG_H
#define VITABROWSER_MACSURF_DEBUG_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * NO declaration of macsurf_debug_log_writef here.
 *
 * netsurf's ported sources already declare it at file scope --
 * content/content_protected.h, html/redraw.c, html/box_construct.c,
 * desktop/textarea.c -- and content.c includes THIS header as well, so
 * declaring it here too trips -Werror=redundant-decls.
 *
 * The libraries are the opposite case: the splitter strips their nested
 * externs, leaving no declaration at all, so they force-include
 * compat/macsurf_lib_decls.h instead. See tools/build-patched.sh.
 */

#ifdef VITABROWSER_ENGINE_TRACE
#define MS_LOG(...) macsurf_debug_log_writef(__VA_ARGS__)
#else
#define MS_LOG(...) ((void) 0)
#endif

#ifdef __cplusplus
}
#endif

#endif /* VITABROWSER_MACSURF_DEBUG_H */
