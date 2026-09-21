/*
 * macsurf_compat.c -- VitaBrowser compatibility shim.
 *
 * MacSurf's engine patches call two runtime helpers that live in their Mac OS 9
 * frontend, which we do not port. The calls survive in ported code, and several
 * of the calling translation units declare the symbols with a nested `extern`
 * rather than including a header, so the declarations cannot be macro'd away --
 * the definitions have to exist at link time.
 *
 *   macsurf_debug_log_writef  hardware trace output. See compat/macsurf_debug.h
 *                             for why tracing is off by default.
 *   macsurf_ptr_is_heap       a Mac OS 9 heap-range check used to decide whether
 *                             a pointer is safe to free. On the Vita there is no
 *                             equivalent concept: every pointer the engine owns
 *                             comes from its own allocator. Returning true keeps
 *                             the callers' behaviour identical to a plain free,
 *                             which is what upstream NetSurf does anyway.
 */
#include <stdarg.h>
#include <stddef.h>

void macsurf_debug_log_writef(const char *fmt, ...);
int macsurf_ptr_is_heap(const void *ptr);

void macsurf_debug_log_writef(const char *fmt, ...)
{
#ifdef VITABROWSER_ENGINE_TRACE
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
#else
	(void) fmt;
#endif
}

int macsurf_ptr_is_heap(const void *ptr)
{
	return ptr != NULL;
}
