/*
 * macsurf_diag.h -- VitaBrowser compatibility shim.
 *
 * MacSurf's diagnostic helpers, included by a ported core source. All of them
 * are observation-only; none affects layout or paint.
 */
#ifndef VITABROWSER_MACSURF_DIAG_H
#define VITABROWSER_MACSURF_DIAG_H

#include "macsurf_debug.h"

/* Microsecond clock. MacSurf reads the 601 timebase via Microseconds();
 * compat/macsurf_compat.c uses clock_gettime. */
double macos9_micros(void);

/* Whether any JS listener is registered for an event type. The real
 * implementation lives in macsurf_qjs.c, which is part of the Mac OS 9
 * frontend and is not ported here. The shim answers "yes", which keeps event
 * dispatch behaving as it does upstream -- upstream has no such filter and
 * dispatches unconditionally. */
int macsurf_qjs_event_type_live(const char *type);

#endif /* VITABROWSER_MACSURF_DIAG_H */
