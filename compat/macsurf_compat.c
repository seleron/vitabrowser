/*
 * macsurf_compat.c -- VitaBrowser compatibility shim.
 *
 * MacSurf's engine patches call three helpers that live outside the five core
 * libraries -- in their Mac OS 9 frontend or in netsurf's utils -- neither of
 * which we port. The calls survive in ported code, and every caller declares
 * the symbol with a nested `extern` rather than including a header, so they
 * cannot be macro'd away: the definitions have to exist at link time.
 *
 * All three are defined weak and this file is compiled into BOTH libcss and
 * libdom. Static archives are searched in link order, so a definition sitting
 * only in libcss is already past by the time libdom's references are resolved.
 * Weak linkage lets both archives carry it without a duplicate-symbol error.
 */
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>

void macsurf_debug_log_writef(const char *fmt, ...);
int macsurf_ptr_is_heap(const void *ptr);
void ns_color_hex_alpha(char *buf, unsigned long col);

/*
 * Hardware trace output. Off unless VITABROWSER_ENGINE_TRACE, but the
 * arguments are still parsed either way -- see compat/macsurf_debug.h for why
 * we keep the option rather than deleting the calls.
 */
__attribute__((weak))
void macsurf_debug_log_writef(const char *fmt, ...)
{
#ifdef VITABROWSER_ENGINE_TRACE
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
#else
	(void) fmt;
#endif
}

/*
 * A Mac OS 9 heap-range check, used to decide whether a pointer is safe to
 * free. There is no equivalent concept here: every pointer the engine owns
 * comes from its own allocator. Returning true for any non-NULL pointer makes
 * the callers behave exactly as upstream NetSurf does.
 */
__attribute__((weak))
int macsurf_ptr_is_heap(const void *ptr)
{
	return ptr != NULL;
}

/*
 * Colour diagnostic (MacSurf fixes1268c). Formats a colour for the trace log
 * only -- never for rendering. Callers pass a 12-byte buffer.
 */
__attribute__((weak))
void ns_color_hex_alpha(char *buf, unsigned long col)
{
	if (buf == NULL)
		return;
	snprintf(buf, 12, "#%02lx%02lx%02lx%02lx",
		 (col >> 16) & 0xffUL, (col >> 8) & 0xffUL,
		 col & 0xffUL, (col >> 24) & 0xffUL);
}
