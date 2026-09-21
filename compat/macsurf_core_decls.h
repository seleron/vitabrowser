/*
 * macsurf_core_decls.h -- VitaBrowser compatibility shim.
 *
 * MacSurf added several functions to netsurf's core but declared them only in
 * their Mac OS 9 frontend, which we do not port. Upstream builds with
 * -Werror=missing-prototypes and -Werror=nested-externs, so a definition with
 * no visible prototype -- or a caller declaring one inline -- is an error.
 *
 * These are all real functions we keep; only their declarations were missing.
 * This header is force-included into the netsurf build (-include) so every
 * translation unit sees them.
 */
#ifndef VITABROWSER_MACSURF_CORE_DECLS_H
#define VITABROWSER_MACSURF_CORE_DECLS_H

#include <stdbool.h>

#include "utils/errors.h"   /* nserror */
#include "macsurf_config.h"

struct content;

/* box_construct.c -- defer a callback until the box walk unwinds, the same
 * re-entrancy hazard macos9_op_depth guards. */
bool box_construct_sched_pins(void (*cb)(void *), void *p,
		struct content *target);

/* box_construct.c -- is the running box walk the owner of this content? */
int macos9_box_walk_owns_content(struct content *c);

/* box_construct.c -- a freed-box registry MacSurf used to chase a
 * double-free. Diagnostics, but the functions are real and are called. */
const char *macsurf_box_freed_lookup(void *box);
void macsurf_box_freed_note(void *box, const char *ctx);

/* utils/talloc.c -- name of the context currently being freed, for the same
 * double-free hunt. Defined in talloc.c; callers declare it inline, which
 * -Wnested-externs rejects. */
extern const char *macsurf_talloc_free_ctx;

/* html/object.c -- re-evaluate lazy-loaded images after a viewport change. */
void macsurf_lazyimg_viewport_changed(int scroll_y, int viewport_h);

/* Reconvert position tracking. Declared here as well as in
 * macsurf_debug_log.h: the splitter strips the nested externs, and not every
 * caller includes that header. Diagnostics only; see macsurf_debug_log.h. */
void macsurf_reconv_pos_set(const char *phase, long seq, long node_ix,
		const char *tag);
void macsurf_reconv_pos_flush(void);

/* ---- the ten that matter ------------------------------------------------
 *
 * MacSurf's debug scaffolding is stripped from the stack rather than stubbed
 * (docs/phase-0/07-netsurf-port.md §8.2), but ten of its frontend-declared
 * symbols are real behaviour and are kept. They are declared here because
 * their definitions live in the Mac OS 9 frontend we do not port; weak
 * definitions in macsurf_compat.c stand in until the Vita frontend supplies
 * the real ones.
 */

struct dom_document;
struct jsthread;
struct browser_window;
struct gui_window;

/* JS bridge hooks. These are how the DOM signals the script thread, so they
 * are behaviour, not diagnostics. The generation counters exist so a late
 * callback can tell whether the thread and realm it was queued against are
 * still the current ones -- a stale-callback guard. */
unsigned char js_fire_dom_ready(struct jsthread *thread,
		struct dom_document *doc);
void js_fire_mutation_batch(struct jsthread *thread);
unsigned long js_realm_generation(struct jsthread *thread);
unsigned long js_thread_generation(struct jsthread *thread);
int js_thread_valid_for_content(struct jsthread *thread,
		unsigned long thread_gen, struct content *c,
		unsigned long realm_gen);

/* Ordinary engine calls MacSurf routes through the frontend. */
void browser_window_set_status(struct browser_window *bw, const char *text);
void css_inline_extras_clear(void);
nserror macos9_schedule(int t, void (*callback)(void *p), void *p);
extern struct gui_window *macos9_paint_gw;

/* ---- core-defined diagnostics ------------------------------------------
 *
 * These look like scaffolding but are DEFINED in the netsurf files we port,
 * not in the Mac OS 9 frontend -- so they are not stripped. They only ever
 * lacked a visible prototype, because MacSurf declared them in the frontend
 * header. Same situation as fetch_pump.
 *
 * Checked per symbol rather than assumed: the frontend-only families
 * (macsurf__site_*, macsurf_profile_*, macos9_heap_*, macos9_font_measure_*,
 * macsurf_debug_log_int) are stripped by the splitter; everything below is
 * defined in core and kept.
 */
void macsurf_obj_fetch_stats(long *fetch, long *spec, long *bg,
		long *adopt, long *renode, long *specdup);
void macsurf_llcache_stats(long *fresh, long *reval, long *miss,
		long *notmod, long *cond);
void macsurf_img_ctor_stats(long *total, long *eager, long *lazy,
		long *rdim, long *dropobj);
void macsurf_img_object_stats(long *done_ok, long *done_zero,
		long *set, long *nulled);
void macsurf_imgdims_stats(int *stored, int *hit, int *miss);

extern int macsurf_reconvert_in_progress;
extern unsigned long macsurf_reconvert_seq;
extern void *macsurf_reconvert_last_layout;
extern unsigned long macsurf_box_backlink_cleared;
extern int macsurf__cascade_probe_armed;

/* Frontend-side plain-string log entry point, distinct from the printf-style
 * one. Weak no-op in macsurf_compat.c, same as its sibling. */
void macsurf_debug_log_write(const char *s);

#endif /* VITABROWSER_MACSURF_CORE_DECLS_H */
