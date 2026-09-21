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
#include <time.h>

struct content;

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

/* ---- netsurf-core shims (see compat/macos9_deathrow.h and macsurf_diag.h) ---- */

/*
 * Run the teardown now. MacSurf queues it because Mac OS 9's cooperative
 * scheduler can re-enter the core from a callback; our single-threaded loop
 * cannot, and upstream NetSurf frees directly at these call sites.
 */
__attribute__((weak))
void macos9_deathrow_add(void *ptr, void (*teardown)(void *ptr),
		struct content *pin_key)
{
	(void) pin_key;
	if (teardown != NULL)
		teardown(ptr);
}

__attribute__((weak))
void macos9_deathrow_drain(void)
{
	/* Nothing is ever queued, so nothing to drain. */
}

/*
 * Liveness registry. Upstream has no such concept and trusts its own
 * lifetimes; answering "live" and "valid" reproduces that.
 */
__attribute__((weak))
int macos9_content_is_live(struct content *c)
{
	return c != NULL;
}

__attribute__((weak))
unsigned long macos9_content_token(struct content *c)
{
	return (unsigned long) (size_t) c;
}

__attribute__((weak))
int macos9_content_token_valid(struct content *c, unsigned long token)
{
	return c != NULL && token == (unsigned long) (size_t) c;
}

/* Reconvert position tracking -- diagnostics only. */
__attribute__((weak))
void macsurf_reconv_pos_set(const char *phase, long seq, long node_ix,
		const char *tag)
{
	(void) phase; (void) seq; (void) node_ix; (void) tag;
}

__attribute__((weak))
void macsurf_reconv_pos_flush(void)
{
}

/* Microsecond clock. MacSurf reads the 601 timebase; we use the monotonic
 * clock, which is what the Vita's sceKernelGetTick will map onto too. */
__attribute__((weak))
double macos9_micros(void)
{
	struct timespec ts;
	if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
		return 0.0;
	return (double) ts.tv_sec * 1000000.0 + (double) ts.tv_nsec / 1000.0;
}

/*
 * Whether a JS event type has live listeners. The real answer lives in
 * macsurf_qjs.c, part of the Mac OS 9 frontend. Answering "yes" dispatches
 * unconditionally, which is upstream's behaviour.
 */
__attribute__((weak))
int macsurf_qjs_event_type_live(const char *type)
{
	(void) type;
	return 1;
}

/*
 * Re-entrancy depth, always zero: our event loop never re-enters the core, so
 * every `if (macos9_op_depth > 0)` guard takes the upstream branch.
 */
__attribute__((weak))
int macos9_op_depth = 0;
