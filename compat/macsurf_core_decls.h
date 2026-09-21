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

/* macsurf_reconv_pos_set/flush are NOT declared here. The two files that use
 * them carry their own file-scope extern, which survives stripping because
 * compat does not claim the symbol -- and claiming it here as well is what
 * tripped -Werror=redundant-decls.
 *
 * Note the coupling: the splitter strips extern declarations for whatever
 * compat declares, so patches must be regenerated after editing these
 * headers. Two failures this session were stale patches, not bad code. */

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
/* css_inline_extras_clear is NOT declared here: it is libcss's own API,
 * declared in libcss/select.h, and MacSurf only added a nested extern for it.
 * Declaring it again trips -Werror=redundant-decls. */
nserror macos9_schedule(int t, void (*callback)(void *p), void *p);
extern struct gui_window *macos9_paint_gw;

/* ---- prototypes MacSurf genuinely omitted -------------------------------
 *
 * Defined in the netsurf files we port, with no declaration anywhere. Note
 * what is NOT here: the _stats family, macsurf_reconvert_seq and friends.
 * MacSurf writes a self-prototype immediately above those definitions, which
 * already satisfies -Wmissing-prototypes -- declaring them again here trips
 * -Wredundant-decls instead. Only the genuinely undeclared ones belong.
 */
struct nsurl;
struct lwc_string_s;
typedef struct lwc_string_s lwc_string;
struct html_content;

nserror html_reconvert(struct html_content *c);
int html_reconvert_content(struct content *c);
struct nsurl *html_macsurf_font_face_url(struct content *c,
		lwc_string *family);
int macsurf_html_has_droppable_inflight(struct content *c);
void *macsurf_reconvert_node_ref(void *n);
void macsurf_reconvert_node_unref(void *n);

/* Frontend-side plain-string log entry point, distinct from the printf-style
 * one. Weak no-op in macsurf_compat.c, same as its sibling. */
void macsurf_debug_log_write(const char *s);

#endif /* VITABROWSER_MACSURF_CORE_DECLS_H */
