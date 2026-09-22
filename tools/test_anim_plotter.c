/* Unit test for patch 27 (animation-timeline plotter) + regression for 25/26.
 *
 * Compiles the REAL patched frontends/monkey/plot.c (from /tmp/p27full, which
 * is pristine + patch25 + patch26 + patch27) against the patched include tree,
 * with a stub moutf() that captures the PLOT stream into a buffer. Then it
 * synthesizes plot_style_t values directly and asserts the exact stream output.
 *
 * This proves the plotter math is correct INDEPENDENTLY of the libcss
 * bytecode->computed round-trip (the same isolation strategy as the
 * gradient _H unit test). The full-page probe is blocked by the libcss
 * round-trip gap (values don't reach plot_style_t), which is a core gap
 * documented separately.
 *
 * Build (single TU; $UP = patched upstream tree with 25+26+27 applied):
 *   UP=$HOME/vitabrowser-work/applytest/upstream
 *   gcc -Wall -Wno-unused-parameter -Wno-misleading-indentation \
 *     -I$UP/netsurf -I$UP/netsurf/include -I$UP/netsurf/utils \
 *     -I$UP/libcss/include -I$UP/libdom/include -I$UP/libhubbub \
 *     -I$UP/libvlib -I$UP/libbitmap -I$UP/libwapcaplet/include \
 *     -I$UP/netsurf/frontends -D_GNU_SOURCE \
 *     tools/test_anim_plotter.c -o /tmp/test_anim
 *   /tmp/test_anim
 */
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>
#include <assert.h>
#include "netsurf/plotters.h"
#include "monkey/output.h"   /* for MOUT_PLOT + moutf decl */

/* Include the REAL patched plot.c so the static monkey_plot_rectangle() is
 * visible in this translation unit. plot.c's own includes resolve via the
 * -I paths; its moutf() calls bind to the stub below. */
#include "monkey/plot.c"

/* ---- stub moutf: capture PLOT lines into a global buffer ---- */
static char g_out[16384];
static size_t g_out_len = 0;

int moutf(enum monkey_output_type mout_type, const char *fmt, ...)
{
	if (mout_type != MOUT_PLOT)
		return 0;
	char tmp[512];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
	va_end(ap);
	if (n > 0) {
		size_t room = sizeof(g_out) - g_out_len - 1;
		if ((size_t)n > room) n = (int)room;
		memcpy(g_out + g_out_len, tmp, (size_t)n);
		g_out_len += (size_t)n;
		g_out[g_out_len] = '\0';
	}
	return 0;
}

/* reset capture buffer */
static void reset_out(void) { g_out[0] = '\0'; g_out_len = 0; }

static struct redraw_context g_ctx;

static int tests_run = 0;
static int tests_failed = 0;

#define CHECK_CONTAINS(needle) do { \
	tests_run++; \
	if (!strstr(g_out, (needle))) { \
		tests_failed++; \
		printf("FAIL: expected to find: %s\n  got: %s\n", (needle), g_out); \
	} else { \
		printf("PASS: contains %s\n", (needle)); \
	} \
} while (0)

#define CHECK_NOT_CONTAINS(needle) do { \
	tests_run++; \
	if (strstr(g_out, (needle))) { \
		tests_failed++; \
		printf("FAIL: expected NOT to find: %s\n  got: %s\n", (needle), g_out); \
	} else { \
		printf("PASS: does not contain %s\n", (needle)); \
	} \
} while (0)

int main(void)
{
	/* ============ TEST 1: static rotate(90) ============
	 * transform = (90 << 6) << 16 = 0x00150000  (Q10.6 deg in bits 30..16)
	 * box: (10,10)-(110,50), 100x40, centre (60,30)
	 * rotate 90 CCW: nx=-dy, ny=dx
	 *   (10,10): dx=-50 dy=-20 -> nx=20 ny=-50 -> (80,-20)
	 *   (110,10): dx=50 dy=-20 -> nx=20 ny=50 -> (80,80)
	 *   (110,50): dx=50 dy=20 -> nx=-20 ny=50 -> (40,80)
	 *   (10,50): dx=-50 dy=20 -> nx=-20 ny=-50 -> (40,-20)
	 * Expected: POLY X0 80 Y0 -20 X1 80 Y1 80 X2 40 Y2 80 X3 40 Y3 -20
	 */
	{
		reset_out();
		plot_style_t s;
		memset(&s, 0, sizeof(s));
		s.fill_type = PLOT_OP_TYPE_SOLID;
		s.fill_colour = 0xff0000;
		s.transform = (90 << 6) << 16;
		s.transform_b = (int)0x01000100;
		struct rect r = {10, 10, 110, 50};
		monkey_plot_rectangle(&g_ctx, &s, &r);
		printf("[TEST1 rotate90] out=%s\n", g_out);
		CHECK_CONTAINS("POLY");
		CHECK_CONTAINS("X0 80 Y0 -20");
		CHECK_CONTAINS("X1 80 Y1 80");
		CHECK_CONTAINS("X2 40 Y2 80");
		CHECK_CONTAINS("X3 40 Y3 -20");
		/* opaque -> no OPAQUE token */
		CHECK_NOT_CONTAINS("OPAQUE");
	}

	/* ============ TEST 2: static rotate(0) + scale 0.5 ============
	 * transform = 0 (no rotation), transform_b = (128,128) = 0x00800080 (0.5)
	 * box (10,10)-(110,50), centre (60,30), scale 0.5:
	 *   corners halved around centre:
	 *   (10,10): dx=-50 dy=-20 -> cx+dx*0.5=60-25=35, cy+dy*0.5=30-10=20 -> (35,20)
	 *   (110,10): 60+25=85, 30-10=20 -> (85,20)
	 *   (110,50): 85, 30+10=40 -> (85,40)
	 *   (10,50): 35, 40 -> (35,40)
	 * Expected: POLY X0 35 Y0 20 X1 85 Y1 20 X2 85 Y2 40 X3 35 Y3 40
	 */
	{
		reset_out();
		plot_style_t s;
		memset(&s, 0, sizeof(s));
		s.fill_type = PLOT_OP_TYPE_SOLID;
		s.fill_colour = 0x00ff00;
		s.transform = 0;
		s.transform_b = 0x00800080;
		struct rect r = {10, 10, 110, 50};
		monkey_plot_rectangle(&g_ctx, &s, &r);
		printf("[TEST2 scale0.5] out=%s\n", g_out);
		CHECK_CONTAINS("POLY");
		CHECK_CONTAINS("X0 35 Y0 20");
		CHECK_CONTAINS("X1 85 Y1 20");
		CHECK_CONTAINS("X2 85 Y2 40");
		CHECK_CONTAINS("X3 35 Y3 40");
	}

	/* ============ TEST 3: opacity 40% -> bucket 2 ============
	 * PLOT_STYLE_SCALE = 1024. 40% = 409.  35%=358, 60%=614.
	 * 358 < 409 < 614 -> bucket 2.
	 * plain rect (no transform) -> RECT ... OPAQUE 2
	 */
	{
		reset_out();
		plot_style_t s;
		memset(&s, 0, sizeof(s));
		s.fill_type = PLOT_OP_TYPE_SOLID;
		s.fill_colour = 0x0000ff;
		s.transform = 0;
		s.transform_b = (int)0x01000100;
		s.opacity = (plot_style_fixed)((1024 * 40) / 100);
		struct rect r = {10, 50, 110, 90};
		monkey_plot_rectangle(&g_ctx, &s, &r);
		printf("[TEST3 opacity40] out=%s\n", g_out);
		CHECK_CONTAINS("RECT");
		CHECK_CONTAINS("OPAQUE 2");
	}

	/* ============ TEST 4: opacity 0 (unset) -> opaque (bucket 4) ============
	 * No OPAQUE token. L1 byte-identity path.
	 */
	{
		reset_out();
		plot_style_t s;
		memset(&s, 0, sizeof(s));
		s.fill_type = PLOT_OP_TYPE_SOLID;
		s.fill_colour = 0x123456;
		s.transform = 0;
		s.transform_b = (int)0x01000100;
		s.opacity = 0;
		struct rect r = {10, 10, 110, 50};
		monkey_plot_rectangle(&g_ctx, &s, &r);
		printf("[TEST4 opacity0] out=%s\n", g_out);
		CHECK_CONTAINS("RECT X0 10 Y0 10 X1 110 Y1 50");
		CHECK_NOT_CONTAINS("OPAQUE");
		CHECK_NOT_CONTAINS("POLY");
	}

	/* ============ TEST 5: opacity 90% -> bucket 4 (solid) ============
	 * 90% = 921. 85% = 870. 921 >= 870 -> bucket 4. No OPAQUE token.
	 */
	{
		reset_out();
		plot_style_t s;
		memset(&s, 0, sizeof(s));
		s.fill_type = PLOT_OP_TYPE_SOLID;
		s.fill_colour = 0x654321;
		s.transform = 0;
		s.transform_b = (int)0x01000100;
		s.opacity = (plot_style_fixed)((1024 * 90) / 100);
		struct rect r = {10, 10, 110, 50};
		monkey_plot_rectangle(&g_ctx, &s, &r);
		printf("[TEST5 opacity90] out=%s\n", g_out);
		CHECK_CONTAINS("RECT X0 10 Y0 10 X1 110 Y1 50");
		CHECK_NOT_CONTAINS("OPAQUE");
	}

	/* ============ TEST 6: transform + opacity combined ============
	 * rotate(90) + opacity 40% -> POLY ... OPAQUE 2
	 */
	{
		reset_out();
		plot_style_t s;
		memset(&s, 0, sizeof(s));
		s.fill_type = PLOT_OP_TYPE_SOLID;
		s.fill_colour = 0xff00ff;
		s.transform = (90 << 6) << 16;
		s.transform_b = (int)0x01000100;
		s.opacity = (plot_style_fixed)((1024 * 40) / 100);
		struct rect r = {10, 10, 110, 50};
		monkey_plot_rectangle(&g_ctx, &s, &r);
		printf("[TEST6 rot90+op40] out=%s\n", g_out);
		CHECK_CONTAINS("POLY");
		CHECK_CONTAINS("X0 80 Y0 -20");
		CHECK_CONTAINS("OPAQUE 2");
	}

	/* ============ TEST 7 (regression 25): vertical gradient 32 strips ============
	 * fill_type = LINEAR_GRADIENT, no transform. Expect 32 RECT strips
	 * (Y-stepping), no POLY, no OPAQUE.
	 */
	{
		reset_out();
		plot_style_t s;
		memset(&s, 0, sizeof(s));
		s.fill_type = PLOT_OP_TYPE_LINEAR_GRADIENT;
		s.fill_colour = 0x000000;
		s.fill_colour2 = 0xffffff;
		s.transform = 0;
		s.transform_b = (int)0x01000100;
		s.opacity = 0;
		struct rect r = {10, 10, 210, 142};
		monkey_plot_rectangle(&g_ctx, &s, &r);
		int strips = 0;
		for (char *p = g_out; (p = strstr(p, "RECT X0")) != NULL; p++) strips++;
		printf("[TEST7 gradient] strips=%d out(first100)=%.*s\n", strips, 100, g_out);
		tests_run++;
		if (strips != 32) { tests_failed++; printf("FAIL: expected 32 strips, got %d\n", strips); }
		else printf("PASS: 32 gradient strips\n");
		CHECK_NOT_CONTAINS("POLY");
		CHECK_NOT_CONTAINS("OPAQUE");
	}

	printf("\n=== %d tests, %d failed ===\n", tests_run, tests_failed);
	return tests_failed ? 1 : 0;
}
