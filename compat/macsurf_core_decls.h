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

#endif /* VITABROWSER_MACSURF_CORE_DECLS_H */
