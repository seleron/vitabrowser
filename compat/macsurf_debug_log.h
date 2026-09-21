/*
 * macsurf_debug_log.h -- VitaBrowser compatibility shim.
 *
 * A second debug-logging entry point MacSurf's core patches include. Same
 * mechanism and same default as compat/macsurf_debug.h; kept as a separate
 * header only because the ported sources include it under this name.
 */
#ifndef VITABROWSER_MACSURF_DEBUG_LOG_H
#define VITABROWSER_MACSURF_DEBUG_LOG_H

#include "macsurf_debug.h"

/* The reconvert position helpers are declared in macsurf_core_decls.h, which
 * is force-included into the whole netsurf build. Declaring them here too
 * would trip -Werror=redundant-decls wherever both headers are reached. */

#endif /* VITABROWSER_MACSURF_DEBUG_LOG_H */
