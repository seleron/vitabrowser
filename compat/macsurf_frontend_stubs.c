/*
 * macsurf_frontend_stubs.c -- vitabrowser
 *
 * Weak stubs for MacSurf symbols defined in frontends/macos9/ (the Mac OS 9
 * frontend this port does not compile). The generated MacSurf patch stack
 * leaves their call sites in the netsurf core; CodeWarrior on Mac OS 9
 * resolved them from the frontend, so they are simply absent here.
 *
 * Categories:
 *   REAL (pure logic, no frontend dependency -- implemented faithfully):
 *     isDigit / isHex / charToHex          libcss lexer helpers
 *     css_error_from_lwc_error             libcss error mapping
 *     css_error_from_parserutils_error
 *     lwc_string_caseless_hash_value       CRITICAL: must equal the hash of
 *                                          the caseless intern, or libcss's
 *                                          selector hash returns nothing and
 *                                          no author CSS ever matches
 *     html_css_discover_stylesheets        DOM walk finding <style>/<link>,
 *                                          registered via css.c's exported
 *                                          update_style/process_link helpers
 *   FUNCTIONAL-NOOP (safe: they only gate/measure, the page still renders):
 *     nscss_reset_node_data,
 *     font_plot_style_baseline,
 *     macos9_content_is_live, js_exec_module, macsurf_js_notify_content_freed,
 *     macos9_hittest_scroll_x/y
 *   (layout_grid and macsurf_html_element_get_tag_type were promoted to real
 *    ports in 2026-09-22: content/handlers/html/layout_grid.c and
 *    macsurf_dom_compat.c, wired in by patch 23.)
 *   INSTRUMENTATION-NOOP (Mac OS 9 diagnostics/tracing/animation/JS-profiling):
 *     macsurf_profile_*, macsurf_diag_*, ms_diag_*, macsurf_gap_*,
 *     macsurf_qjs_*, macos9_animation_*, macos9_grad_*_count,
 *     macsurf_free_mem, macsurf_ptr_is_valid, macsurf_debug_log_reconv_flush,
 *     macos9_deathrow_cur_ptr/fn
 *
 * Known functional gaps (documented in docs/phase-0/08): CSS grid,
 * font-baseline tuning, inline ES modules.
 *
 * Compiled into content/handlers/html/ (has the libcss/libdom/libwapcaplet
 * include paths). Weak, so a real implementation (the Vita frontend) can
 * replace any of these without touching this file.
 */
#include <stddef.h>
#include <string.h>
#include <libcss/errors.h>
#include <libcss/properties.h>
#include <libwapcaplet/libwapcaplet.h>
#include <dom/dom.h>
#include <dom/html/html_element.h>

/* html_css_discover_stylesheets (REAL below) walks the DOM and needs the
 * full html_content definition (->document, ->stylesheets_discovered) plus
 * the two exported stylesheet-registration helpers that css.c already
 * provides. private.h is core-only (css.c includes it in the same build);
 * it is the only heavy include this file drags in. */
#include "utils/errors.h"
#include "utils/log.h"
#include "html/private.h"
#include "utils/corestrings.h"
#include "utils/nsoption.h"

/* css.c exports (css.h:87, css.h:105). Declared here so we don't pull in
 * the rest of css.h; the linker resolves them to the real definitions. */
extern bool html_css_update_style(struct html_content *c, dom_node *style);
extern bool html_css_process_link(struct html_content *c, dom_node *node);

/* Pointer-only parameters; full definitions live in layout.h / content.h
 * which the stubs must not drag in (frontend-entangled includes). */
struct box;
struct content;

/* ============================ REAL implementations ======================= */

int isDigit(unsigned char c) { return c >= '0' && c <= '9'; }

int isHex(unsigned char c)
{
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
	       (c >= 'A' && c <= 'F');
}

unsigned long charToHex(unsigned char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return 0;
}

/* css_error:  0=OK 1=NOMEM 2=BADPARM 3=INVALID 4=FILENOTFOUND 5=NEEDDATA
 *              6=BADCHARSET 7=EOF
 * lwc_error:  0=ok 1=oom 2=range
 *
 * css_error_from_parserutils_error MUST be a 1:1 cast. The css_error and
 * parserutils_error enums are value-aligned (both 0..7 in the same order),
 * and upstream libcss/src/utils/parserutilserror.h defines it exactly as
 * `(css_error) error`. A default-to-CSS_INVALID switch was fatal: it turned
 * PARSERUTILS_NEEDDATA (5) -- a *recoverable* "feed me more data" signal the
 * streaming parser emits on every chunked append -- into CSS_INVALID (3),
 * which invalidated the base sheet (default.css) and raised NSERROR_CSS_BASE
 * on every page. Keep it a plain cast.
 *
 * css_error_from_lwc_error: lwc is {ok,oom,range}; oom is the only one worth
 * propagating, everything else maps to INVALID (matches upstream lwcerr.h).
 */
int css_error_from_lwc_error(int err)
{
	switch (err) { case 0: return CSS_OK; case 1: return CSS_NOMEM;
	                default: return CSS_INVALID; }
}

int css_error_from_parserutils_error(int err)
{
	return (css_error) err;
}

/* MUST return lwc_string_hash_value(str->insensitive): libcss inserts
 * selector names keyed by the caseless intern's hash and looks them up with
 * this function. Disagreeing buckets = every selector silently unmatched. */
lwc_error lwc_string_caseless_hash_value(lwc_string *str, lwc_hash *hash)
{
	lwc_error err;
	if (str == NULL || hash == NULL) return lwc_error_range;
	if (str->insensitive == NULL) {
		err = lwc__intern_caseless_string(str);
		if (err != lwc_error_ok) return err;
	}
	*hash = lwc_string_hash_value(str->insensitive);
	return lwc_error_ok;
}

/* ======================== FUNCTIONAL no-op stubs ========================= */

/* ================= REAL: author-CSS stylesheet discovery ================
 *
 * html.c:2486 walks the parsed DOM before conversion and calls this once
 * (guarded by c->stylesheets_discovered) to find every <style> and
 * <link rel="stylesheet"> and start their CSS fetch. Upstream NetSurf
 * discovered these via the libdom DOMSubtreeModified/DOMNodeInserted event
 * chain; MacSurf (which we port from) replaced that with an explicit
 * pre-conversion walk because the event chain is unreliable in its build.
 *
 * The old stub here was a no-op, so NO author stylesheet was ever
 * registered/parsed/applied -- only the UA stylesheet (default.css). Every
 * page rendered at the UA 8px body margin and author <style>/<link> was
 * silently dropped (see docs/phase-0/06 §7: margin:50px -> X=8, not X=50).
 *
 * We implement the walk with the two stylesheet-registration helpers that
 * css.c ALREADY exports (html_css_update_style / html_css_process_link) and
 * that are compiled into this same target. The walk is the frontend-agnostic
 * part; the fetch/parse/convert machinery (the modified flag that gates
 * html_can_begin_conversion, the x-ns-css fetcher, html_convert_css_callback)
 * is all upstream and already present. This is what MacSurf's
 * html_css_register_inline_style_sync / html_css_process_link do, minus the
 * frontends/macos9/ includes that cannot build here.
 *
 * Signature matches the declaration in html/css.h:119 and the call site in
 * html.c:2486. */
__attribute__((weak)) nserror html_css_discover_stylesheets(struct html_content *c)
{
	dom_node *root = NULL;
	dom_node *node = NULL;
	dom_node *next = NULL;
	dom_node *child = NULL;
	dom_node *parent = NULL;
	dom_exception exc;
	dom_node_type ntype;
	dom_string *tagname = NULL;
	long style_found = 0;
	long link_found = 0;

	if (c == NULL) {
		return NSERROR_BAD_PARAMETER;
	}
	if (c->stylesheets_discovered) {
		return NSERROR_OK;
	}
	if (c->document == NULL) {
		return NSERROR_OK;
	}

	exc = dom_document_get_document_element(c->document, &root);
	if ((exc != DOM_NO_ERR) || (root == NULL)) {
		return NSERROR_OK;
	}

	/* Iterative depth-first walk: child -> sibling -> parent.sibling.
	 * We ref the node we descend into and unref the one we leave, keeping
	 * exactly one ref outstanding besides the current node. */
	node = root;
	while (node != NULL) {
		exc = dom_node_get_node_type(node, &ntype);
		if ((exc == DOM_NO_ERR) && (ntype == DOM_ELEMENT_NODE)) {
			exc = dom_node_get_node_name(node, &tagname);
			if ((exc == DOM_NO_ERR) && (tagname != NULL)) {
				if (dom_string_caseless_lwc_isequal(
						tagname,
						corestring_lwc_style)) {
					/* Inline <style>. update_style
					 * creates the slot, marks it
					 * modified, and schedules the
					 * fetch; the modified flag then
					 * holds conversion until the
					 * sheet is loaded. */
					if (nsoption_bool(author_level_css)) {
						(void)html_css_update_style(c, node);
						style_found++;
					}
				} else if (dom_string_caseless_lwc_isequal(
						tagname,
						corestring_lwc_link)) {
					/* process_link self-gates on
					 * author_level_css, rel, type and
					 * media; only starts a fetch for a
					 * real rel=stylesheet link. */
					(void)html_css_process_link(c, node);
					link_found++;
				}
				dom_string_unref(tagname);
				tagname = NULL;
			}
		}

		/* Descend to first child if present. */
		child = NULL;
		exc = dom_node_get_first_child(node, &child);
		if ((exc == DOM_NO_ERR) && (child != NULL)) {
			dom_node_unref(node);
			node = child;
			continue;
		}

		/* Else move to next sibling if present. */
		next = NULL;
		exc = dom_node_get_next_sibling(node, &next);
		if ((exc == DOM_NO_ERR) && (next != NULL)) {
			dom_node_unref(node);
			node = next;
			continue;
		}

		/* Leaf with no sibling: climb until we find a parent that has a
		 * next sibling, or run out of tree. */
		for (;;) {
			parent = NULL;
			exc = dom_node_get_parent_node(node, &parent);
			dom_node_unref(node);
			node = NULL;
			if ((exc != DOM_NO_ERR) || (parent == NULL)) {
				break;
			}
			next = NULL;
			exc = dom_node_get_next_sibling(parent, &next);
			if ((exc == DOM_NO_ERR) && (next != NULL)) {
				dom_node_unref(parent);
				node = next;
				break;
			}
			node = parent;
		}
	}

	c->stylesheets_discovered = true;
	NSLOG(netsurf, INFO,
	      "discover: %ld <style> + %ld <link> elements found",
	      style_found, link_found);
	return NSERROR_OK;
}

__attribute__((weak)) int nscss_reset_node_data(void *node)
{
	(void) node;
	return 0;
}

__attribute__((weak)) int font_plot_style_baseline(const void *fstyle,
		int line_height)
{
	(void) fstyle;
	return (line_height * 3 + 2) / 4;
}

__attribute__((weak)) int macos9_content_is_live(const void *c)
{
	/* html.c defines a macro that forces 1 when the symbol is unused;
	 * when it is used, "treat everything as live" is the safe default
	 * (the MacSurf registry exists to detect double-free, not to gate
	 * rendering). */
	(void) c;
	return 1;
}

__attribute__((weak)) unsigned char js_exec_module(void *thread,
		const unsigned char *txt, size_t txtlen, const char *name)
{
	/* No QJS module loader (it lives in the frontend). Inline ES modules
	 * are dropped; classic <script> (js_exec) is unaffected. */
	(void) thread; (void) txt; (void) txtlen; (void) name;
	return 0;
}

__attribute__((weak)) void macsurf_js_notify_content_freed(void *c)
{
	(void) c;
}

/* Frontend scroll offset used by interaction.c's sticky-header math.
 * The Vita frontend sets these around mouse events; 0 = no offset. */
int macos9_hittest_scroll_x = 0;
int macos9_hittest_scroll_y = 0;

/* ========================== INSTRUMENTATION no-ops ======================= */

long macos9_grad_set_count = 0;
long macos9_grad_radial_unpack_count = 0;
long macos9_grad_linear_unpack_count = 0;

void *macos9_deathrow_cur_ptr = NULL;
void *macos9_deathrow_cur_fn = NULL;

__attribute__((weak)) void macsurf_profile_emit_phases(const char *url)
{
	(void) url;
}

__attribute__((weak)) void macsurf_profile_nav_begin(void)
{
}

__attribute__((weak)) void macsurf_diag_nav_done(unsigned long nav_id)
{
	(void) nav_id;
}

__attribute__((weak)) unsigned long ms_diag_cur_nav(void)
{
	return 0;
}

__attribute__((weak)) void ms_diag_frame_open(void *bw)
{
	(void) bw;
}

__attribute__((weak)) void ms_diag_frame_close(void *bw)
{
	(void) bw;
}

__attribute__((weak)) void macsurf_gap_emit_summary(unsigned long nav_id)
{
	(void) nav_id;
}

__attribute__((weak)) void macsurf_qjs_emit_timer_profile(void)
{
}

__attribute__((weak)) void macsurf_qjs_emit_js_profile(void)
{
}

__attribute__((weak)) void macsurf_qjs_set_event_detail(int x, int y,
		int button, int key, int mods)
{
	(void) x; (void) y; (void) button; (void) key; (void) mods;
}

__attribute__((weak)) void macsurf_qjs_clear_event_detail(void)
{
}

__attribute__((weak)) void macos9_animation_register(void)
{
}

__attribute__((weak)) void macos9_animation_register_rect(int x, int y,
		int w, int h)
{
	(void) x; (void) y; (void) w; (void) h;
}

__attribute__((weak)) unsigned int macos9_animation_now_ticks(void)
{
	static unsigned int t = 0;
	return t++;
}

__attribute__((weak)) long macsurf_free_mem(void)
{
	return -1;
}

__attribute__((weak)) int macsurf_ptr_is_valid(const void *p)
{
	(void) p;
	return 1;
}

__attribute__((weak)) void macsurf_debug_log_reconv_flush(int on)
{
	(void) on;
}

/* Cascade probe flag: html.c sets it around the cascade call for the
 * frontend's timing probe; nothing functional depends on its value. */
int macsurf__cascade_probe_armed = 0;
