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
#include <stdlib.h>
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
	if (getenv("MS_TRACE") == NULL) {
		(void) fmt;
		return;
	}
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
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

/* ---- frontend hooks the Vita frontend will eventually own ----------------
 *
 * Weak, so the real Vita frontend overrides them simply by defining them.
 * Each returns the value that keeps the caller on upstream NetSurf's path.
 */

struct jsthread;
struct dom_document;
struct browser_window;
struct gui_window;

/* No script thread here, so DOMContentLoaded cannot fire: report "not
 * fired", which is what upstream does when JS is disabled. */
__attribute__((weak))
unsigned char js_fire_dom_ready(struct jsthread *thread,
		struct dom_document *doc)
{
	(void) thread; (void) doc;
	return 0;
}

__attribute__((weak))
void js_fire_mutation_batch(struct jsthread *thread)
{
	(void) thread;
}

/*
 * Generation counters. MacSurf uses these so a late callback can tell whether
 * the thread and realm it was queued against are still current. With a single
 * generation there is nothing to distinguish, so both report 0 and
 * js_thread_valid_for_content answers "valid" -- the upstream behaviour, which
 * is to run the callback.
 */
__attribute__((weak))
unsigned long js_realm_generation(struct jsthread *thread)
{
	(void) thread;
	return 0;
}

__attribute__((weak))
unsigned long js_thread_generation(struct jsthread *thread)
{
	(void) thread;
	return 0;
}

__attribute__((weak))
int js_thread_valid_for_content(struct jsthread *thread,
		unsigned long thread_gen, struct content *c,
		unsigned long realm_gen)
{
	(void) thread; (void) thread_gen; (void) c; (void) realm_gen;
	return 1;
}

/* Frontend scheduler and paint target. The Vita frontend supplies both; until
 * then scheduling is a no-op, which means a deferred callback never runs --
 * acceptable for headless monkey builds, NOT acceptable on device. */
__attribute__((weak))
struct gui_window *macos9_paint_gw = NULL;

__attribute__((weak))
void macsurf_debug_log_write(const char *s)
{
#ifdef VITABROWSER_ENGINE_TRACE
	if (s != NULL)
		fprintf(stderr, "%s\n", s);
#else
	(void) s;
#endif
}

/*
 * <script> load notification and document.currentScript. Bridge behaviour
 * rather than diagnostics, so they are declared and stubbed rather than
 * stripped -- the real implementations live in macsurf_qjs.c, which is part of
 * the Mac OS 9 frontend. With no script thread there is nothing to notify.
 */
struct dom_node;

__attribute__((weak))
void js_fire_script_load(struct jsthread *thread, struct dom_node *node,
		int success)
{
	(void) thread; (void) node; (void) success;
}

__attribute__((weak))
void js_set_current_script(struct jsthread *thread, struct dom_node *node)
{
	(void) thread; (void) node;
}

/*
 * Navigation phase profiler, defined in frontends/macos9/macsurf_debug_log.c
 * (the frontend we do not port). MacSurf ships a no-op fallback for exactly
 * the build without the real profiler, so these stubs are faithful. The Vita
 * frontend will supply real ones if profiling the engine proves useful.
 */
__attribute__((weak))
void macsurf_profile_emit_phases(const char *url)
{
	(void) url;
}

__attribute__((weak))
void macsurf_profile_nav_begin(void)
{
}
