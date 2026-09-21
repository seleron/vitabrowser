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

/* Reconvert position tracking. Pure diagnostics: MacSurf used these to narrow
 * a use-after-free during content reconversion by recording how far the walk
 * had got. No effect on rendering, so the shim discards them. */
void macsurf_reconv_pos_set(const char *phase, long seq, long node_ix,
		const char *tag);
void macsurf_reconv_pos_flush(void);

#endif /* VITABROWSER_MACSURF_DEBUG_LOG_H */
