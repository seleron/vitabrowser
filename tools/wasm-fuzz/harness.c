/* ASan/UBSan harness for macsurf_wasm.c (patch 254, tools/test-wasm.sh):
 * the real file, wasm3
 * and QuickJS-ng; the frontend and bridge hooks stubbed. Evaluates the
 * WebAssembly part of vita_polyfill.js, then a test script. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "quickjs.h"
#include "macsurf_wasm.h"

double macos9_micros(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e6 + t.tv_nsec / 1e3; }
void macsurf_debug_log_writef(const char *fmt, ...) { (void)fmt; }
static int slices;
int macsurf_wasm_slice(unsigned int ms) { (void)ms; slices++; return getenv("STOP_AT") && slices >= atoi(getenv("STOP_AT")); }
void macsurf_wasm_done(unsigned int ms, unsigned int n) { (void)ms; (void)n; }
static double paused;
void macsurf_qjs_pause_script_clock(double ms) { paused += ms; }
long macsurf_qjs_ncalls, macsurf_qjs_native_us, macsurf_qjs_native_samp;
void macsurf_qjs_gc_note(long us) { (void)us; }

static char *slurp(const char *p, size_t *n)
{
	FILE *f = fopen(p, "rb"); char *b; long l;
	if (!f) { perror(p); exit(2); }
	fseek(f, 0, SEEK_END); l = ftell(f); fseek(f, 0, SEEK_SET);
	b = malloc(l + 1); *n = fread(b, 1, l, f); b[*n] = 0; fclose(f); return b;
}

static JSValue js_gc(JSContext *ctx, JSValueConst t, int c, JSValueConst *a) { (void)t; (void)c; (void)a; JS_RunGC(JS_GetRuntime(ctx)); return JS_UNDEFINED; }
static JSValue js_print(JSContext *ctx, JSValueConst t, int c, JSValueConst *a) { const char *s = JS_ToCString(ctx, a[0]); (void)t; (void)c; printf("%s\n", s); JS_FreeCString(ctx, s); return JS_UNDEFINED; }

static int eval(JSContext *ctx, const char *src, size_t n, const char *name)
{
	JSValue r = JS_Eval(ctx, src, n, name, 0);
	if (JS_IsException(r)) {
		JSValue e = JS_GetException(ctx);
		const char *s = JS_ToCString(ctx, e);
		printf("EXCEPTION in %s: %s\n", name, s);
		JS_FreeCString(ctx, s); JS_FreeValue(ctx, e);
		return 1;
	}
	JS_FreeValue(ctx, r);
	return 0;
}

int main(int argc, char **argv)
{
	JSRuntime *rt = JS_NewRuntime();
	JSContext *ctx = JS_NewContext(rt);
	JSValue g = JS_GetGlobalObject(ctx);
	size_t n1, n2;
	char *poly = slurp(argv[1], &n1), *test = slurp(argv[2], &n2);
	int bad;
	JSContext *c2;
	(void)argc;
	macsurf_wasm_init_class(rt);
	macsurf_wasm_install(ctx, g);
	JS_SetPropertyStr(ctx, g, "gc", JS_NewCFunction(ctx, js_gc, "gc", 0));
	JS_SetPropertyStr(ctx, g, "print", JS_NewCFunction(ctx, js_print, "print", 1));
	JS_FreeValue(ctx, g);
	bad = eval(ctx, poly, n1, "wasm-polyfill") || eval(ctx, test, n2, "test");
	/* drain promise jobs */
	while (JS_ExecutePendingJob(rt, &c2) > 0) ;
	free(poly); free(test);
	JS_FreeContext(ctx);
	JS_FreeRuntime(rt);
	printf("slices %d, paused %.0f ms\n", slices, paused);
	return bad;
}
