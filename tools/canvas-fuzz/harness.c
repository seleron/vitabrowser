/* ASan/UBSan harness for macsurf_canvas.c (patch 251, tools/test-canvas-raster.sh):
 * the real file and QuickJS-ng, the engine hooks stubbed; a JS fuzzer
 * (fuzz.js) drives every __cv native. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "quickjs.h"
#include "utils/errors.h"
#include "netsurf/bitmap.h"
#include "desktop/gui_table.h"
#include <dom/dom.h>

struct netsurf_table *guit = NULL;
dom_string *corestring_dom___ns_key_canvas_node_data;
dom_string *corestring_dom___ns_key_box_node_data;
dom_string *corestring_dom___ns_key_html_content_data;
bool dom_string_isequal(const dom_string *a, const dom_string *b) { return a == b; }
struct html_content; struct box;
void html__redraw_a_box(struct html_content *h, struct box *b) { (void)h; (void)b; }
nserror macos9_schedule(int t, void (*cb)(void *p), void *p) { (void)t; (void)cb; (void)p; return NSERROR_OK; }
void *macsurf_try_alloc(size_t n) { return malloc(n); }
typedef void (*macsurf_glyph_fn)(void *pw, const unsigned char *cov, int stride, int x, int y, int w, int h);
static unsigned char glyph[40 * 40];
int macsurf_canvas_glyphs(int px, int family, int bold, int italic, const char *utf8, size_t len, int x, int y, macsurf_glyph_fn fn, void *pw)
{
	size_t i; int pen = x, gw = px < 40 ? px : 40;
	(void)family; (void)bold; (void)italic;
	for (i = 0; i < len; i++) {
		if (fn) fn(pw, glyph, 40, pen, y - gw, gw, gw);
		if (pen > 2000000) break;
		pen += gw / 2 + 1;
	}
	return pen - x;
}
void macsurf_canvas_font_extents(int px, int f, int b, int it, int *a, int *d) { (void)f; (void)b; (void)it; *a = px; *d = px / 4; }

#include "macsurf_canvas.h"
static struct dom_node *no_node(JSValueConst v) { (void)v; return NULL; }
static struct bitmap *no_bm(JSContext *c, struct dom_node *n) { (void)c; (void)n; return NULL; }
static const struct macsurf_canvas_ops ops = { no_node, no_bm };

int main(int argc, char **argv)
{
	JSRuntime *rt = JS_NewRuntime();
	JSContext *ctx = JS_NewContext(rt);
	JSValue g, r;
	FILE *f = fopen(argv[1], "rb");
	static char src[1 << 20];
	size_t n;
	(void)argc;
	memset(glyph, 200, sizeof(glyph));
	n = fread(src, 1, sizeof(src) - 1, f); fclose(f); src[n] = 0;
	macsurf_canvas_init_class(rt);
	g = JS_GetGlobalObject(ctx);
	macsurf_canvas_install(ctx, g, &ops);
	JS_FreeValue(ctx, g);
	r = JS_Eval(ctx, src, n, "fuzz.js", 0);
	if (JS_IsException(r)) {
		JSValue e = JS_GetException(ctx);
		const char *s = JS_ToCString(ctx, e);
		printf("EXCEPTION: %s\n", s);
		JS_FreeCString(ctx, s); JS_FreeValue(ctx, e);
		return 1;
	}
	{ const char *s = JS_ToCString(ctx, r); printf("%s\n", s); JS_FreeCString(ctx, s); }
	JS_FreeValue(ctx, r);
	JS_FreeContext(ctx);
	JS_FreeRuntime(rt);
	return 0;
}
long macsurf_qjs_ncalls, macsurf_qjs_native_us, macsurf_qjs_native_samp;
void macsurf_qjs_gc_note(long us) { (void)us; }
double macos9_micros(void) { return 0; }
