/* Host-side test for the Vita frontend renderer (frontends/vita, patch 31).
 *
 * Four layers, each against something already verified:
 *
 *  A. CONTRACT. vita_geom_rectangle() must reproduce the monkey plot stream
 *     byte for byte. The reference is the REAL patched monkey plot.c
 *     (tools/test_vita_monkey_tu.c), run on the same plot_style_t: the hand
 *     cases from docs/phase-0/06-engine-comparison.md §6c-6e plus a seeded
 *     fuzz over every field the contract reads.
 *
 *  B. BACKEND. The vita2d plotter table, linked against a logging stub of
 *     <vita2d.h> (tools/vita-stub), must turn each piece into the right
 *     vita2d call: colours, alpha per opacity bucket, triangle fans for
 *     quads, MacSurf's paint rules (default grey drop shadow, colour-0 inset
 *     skipped), clipping.
 *
 *  C. STREAM REPLAY. Every recorded stream (testpages/golden/ *.plot, the
 *     pristine-engine goldens, and testpages/patched-streams/ *.plot, the
 *     patched engine's probe pages) is fed through vita/replay.c. Each op
 *     must reach vita2d as exactly one call with the stream's geometry.
 *
 *  D. INK CLIP. On the patched-engine captures, drop shadows and transform
 *     quads lie inside the clip in force when drawn (patch 32), and a CSS
 *     clip rect still clips them.
 *
 * Build and run: tools/test-vita-renderer.sh
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>
#include <dirent.h>

#include <vita2d.h>

#include "netsurf/plotters.h"
#include "vita/plot_geom.h"
#include "vita/plot.h"
#include "vita/replay.h"
#include "vita/diag.h"
#include "vita/text.h"

void test_monkey_rectangle(const plot_style_t *style, const struct rect *r,
			   char *out, size_t cap);

/* ---------------------------------------------------------------------
 * vita2d stub: every call appends one line to the log.
 */
static char vlog[1 << 20];
static size_t vlog_len;
static unsigned int vcalls;

static void vlogf(const char *fmt, ...)
{
	va_list ap;
	int n;

	va_start(ap, fmt);
	n = vsnprintf(vlog + vlog_len, sizeof(vlog) - vlog_len, fmt, ap);
	va_end(ap);
	if (n > 0 && vlog_len + (size_t)n + 1 < sizeof(vlog)) {
		vlog_len += (size_t)n;
		vlog[vlog_len++] = '\n';
		vlog[vlog_len] = '\0';
	}
	vcalls++;
}

static void vlog_reset(void)
{
	vlog_len = 0;
	vlog[0] = '\0';
	vcalls = 0;
}

static unsigned char pool[1 << 16];
static size_t pool_used;

int vita2d_init(void) { return 0; }
int vita2d_fini(void) { return 0; }
void vita2d_wait_rendering_done(void) { vlogf("wait"); }
void vita2d_start_drawing(void) { vlogf("start"); }
void vita2d_end_drawing(void) { vlogf("end"); }
void vita2d_clear_screen(void) { vlogf("clear"); }
void vita2d_swap_buffers(void) { vlogf("swap"); }
void vita2d_set_clear_color(unsigned int c) { vlogf("clearcolor #%08x", c); }
void vita2d_set_vblank_wait(int e) { (void)e; }
void vita2d_enable_clipping(void) { vlogf("clip-on"); }
void vita2d_disable_clipping(void) { vlogf("clip-off"); }
void vita2d_set_clip_rectangle(int a, int b, int c, int d)
{
	vlogf("clip %d %d %d %d", a, b, c, d);
}
void *vita2d_pool_memalign(unsigned int size, unsigned int align)
{
	size_t at = (pool_used + align - 1) / align * align;
	if (at + size > sizeof(pool))
		at = 0;	/* the test never holds a frame's worth */
	pool_used = at + size;
	return pool + at;
}
void vita2d_pool_reset(void) { pool_used = 0; }
void vita2d_draw_line(float x0, float y0, float x1, float y1, unsigned int c)
{
	vlogf("line %g %g %g %g #%08x", x0, y0, x1, y1, c);
}
void vita2d_draw_rectangle(float x, float y, float w, float h, unsigned int c)
{
	vlogf("rect %g %g %g %g #%08x", x, y, w, h, c);
}
void vita2d_draw_fill_circle(float x, float y, float r, unsigned int c)
{
	vlogf("circle %g %g %g #%08x", x, y, r, c);
}
void vita2d_draw_array(SceGxmPrimitiveType mode, const vita2d_color_vertex *v,
		       size_t count)
{
	char buf[1024];
	size_t n = 0, i;

	n += (size_t)snprintf(buf + n, sizeof(buf) - n, "%s %zu",
		mode == SCE_GXM_PRIMITIVE_TRIANGLE_FAN ? "fan" : "array",
		count);
	for (i = 0; i < count && n < sizeof(buf); i++)
		n += (size_t)snprintf(buf + n, sizeof(buf) - n, " %g,%g",
				      v[i].x, v[i].y);
	if (n < sizeof(buf))
		snprintf(buf + n, sizeof(buf) - n, " #%08x",
			 count ? v[0].color : 0);
	vlogf("%s", buf);
}
vita2d_texture *vita2d_create_empty_texture(unsigned int w, unsigned int h)
{
	vita2d_texture *t = calloc(1, sizeof(*t));
	t->w = w;
	t->h = h;
	t->stride = ((w + 7) & ~7u) * 4;	/* vita2d pads rows to 8 px */
	t->data = calloc(t->stride, h);
	return t;
}
void vita2d_free_texture(vita2d_texture *t)
{
	if (t) {
		free(t->data);
		free(t);
	}
}
unsigned int vita2d_texture_get_width(const vita2d_texture *t) { return t->w; }
unsigned int vita2d_texture_get_height(const vita2d_texture *t) { return t->h; }
unsigned int vita2d_texture_get_stride(const vita2d_texture *t) { return t->stride; }
void *vita2d_texture_get_datap(const vita2d_texture *t) { return t->data; }
void vita2d_draw_texture_scale(const vita2d_texture *t, float x, float y,
			       float sx, float sy)
{
	vlogf("tex %ux%u %g %g %g %g", t->w, t->h, x, y, sx, sy);
}
/* The text engine (vita/text.c) is FreeType and fonts, and has its own
 * test (tools/test_vita_text.c); here it logs what plot.c asks of it. A
 * glyph is 10 px wide, ascent 0.8 em, descent 0.2 em. */
nserror vita_text_init(const char *dir) { (void)dir; return NSERROR_OK; }
void vita_text_fini(void) { }
void vita_text_style_default(struct vita_text_style *s, int px)
{
	s->px = px; s->family = VITA_FAMILY_SANS; s->bold = s->italic = false;
}
void vita_text_style_from_plot(const plot_font_style_t *f,
			       struct vita_text_style *s)
{
	vita_text_style_default(s, (int)((f->size * 96 / 72 +
					  PLOT_STYLE_SCALE / 2) /
					 PLOT_STYLE_SCALE));
	s->bold = f->weight >= 600;
}
int vita_text_width(const struct vita_text_style *s, const char *t,
		    size_t len)
{
	(void)s; (void)t;
	return (int)len * 10;
}
void vita_text_extents(const struct vita_text_style *s, int *a, int *d)
{
	*a = s->px * 8 / 10;
	*d = s->px * 2 / 10;
}
int vita_text_draw(const struct vita_text_style *s, int x, int y,
		   const char *t, size_t len, unsigned int rgba)
{
	vlogf("text %d %d #%08x %dpx%s '%.*s'", x, y, rgba, s->px,
	      s->bold ? " bold" : "", (int)len, t);
	return (int)len * 10;
}
vita2d_texture *vita2d_create_empty_texture_format(unsigned int w,
		unsigned int h, SceGxmTextureFormat f)
{
	(void)f;
	return vita2d_create_empty_texture(w, h);
}
void vita2d_texture_set_filters(vita2d_texture *t, SceGxmTextureFilter a,
				SceGxmTextureFilter b)
{
	(void)t; (void)a; (void)b;
}
void vita2d_draw_texture_tint_part(const vita2d_texture *t, float x, float y,
				   float tx, float ty, float tw, float th,
				   unsigned int c)
{
	vlogf("glyph %g %g", x, y);
	(void)t; (void)tx; (void)ty; (void)tw; (void)th; (void)c;
}

/* The bitmap plotter needs a texture; the real one is in vita/bitmap.c,
 * which this test does not link (its table pulls in core headers only,
 * but it is exercised by the cross build). */
struct bitmap { vita2d_texture *tex; };

/* Owned by vita/diag.c, which this test does not link. */
FILE *vita_plot_trace;
struct vita2d_texture *vita_bitmap_texture(struct bitmap *b)
{
	return b ? b->tex : NULL;
}

/* ---------------------------------------------------------------------
 * harness
 */
static int run, failed;

#define CHECK(cond, ...) do { \
	run++; \
	if (!(cond)) { \
		failed++; \
		printf("FAIL %s:%d: ", __FILE__, __LINE__); \
		printf(__VA_ARGS__); \
		printf("\n"); \
	} \
} while (0)

static const struct plotter_table *P;
static struct redraw_context ctx;

static plot_style_t style0(void)
{
	plot_style_t s;
	memset(&s, 0, sizeof(s));
	s.fill_type = PLOT_OP_TYPE_SOLID;
	return s;
}

/* --- A. contract ---------------------------------------------------- */

static char gbuf[8192];
static size_t glen;

static void fmt_rect(void *pw, enum vita_geom_kind kind, int x0, int y0,
		     int x1, int y1, colour c, int bucket, bool paint)
{
	glen += (size_t)vita_geom_format_rect(gbuf + glen, sizeof(gbuf) - glen,
					      x0, y0, x1, y1, bucket);
	glen += (size_t)snprintf(gbuf + glen, sizeof(gbuf) - glen, "\n");
}

static void fmt_quad(void *pw, const int x[4], const int y[4], colour c,
		     int bucket, bool paint)
{
	glen += (size_t)vita_geom_format_quad(gbuf + glen, sizeof(gbuf) - glen,
					      x, y, bucket);
	glen += (size_t)snprintf(gbuf + glen, sizeof(gbuf) - glen, "\n");
}

static const struct vita_geom_sink fmt_sink = { fmt_rect, fmt_quad, NULL };

/** Run both implementations; return 1 if the streams match. */
static int contract_same(const plot_style_t *s, const struct rect *r,
			 int verbose)
{
	static char mbuf[8192];

	test_monkey_rectangle(s, r, mbuf, sizeof(mbuf));
	glen = 0;
	gbuf[0] = '\0';
	vita_geom_rectangle(s, r, &fmt_sink);
	if (strcmp(mbuf, gbuf) != 0) {
		if (verbose)
			printf("  monkey:\n%s  vita:\n%s", mbuf, gbuf);
		return 0;
	}
	return 1;
}

static uint64_t rng = 0x9e3779b97f4a7c15ull;
static uint32_t rnd(void)
{
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return (uint32_t)(rng >> 16);
}
static int rrange(int lo, int hi) { return lo + (int)(rnd() % (uint32_t)(hi - lo + 1)); }

static void random_style(plot_style_t *s, struct rect *r)
{
	static const plot_operation_type_t fills[] = {
		PLOT_OP_TYPE_NONE, PLOT_OP_TYPE_SOLID, PLOT_OP_TYPE_DOT,
		PLOT_OP_TYPE_DASH, PLOT_OP_TYPE_LINEAR_GRADIENT,
		PLOT_OP_TYPE_LINEAR_GRADIENT_H, PLOT_OP_TYPE_RADIAL_GRADIENT
	};
	memset(s, 0, sizeof(*s));
	s->fill_type = fills[rnd() % 7];
	s->stroke_type = fills[rnd() % 4];
	s->fill_colour = rnd() & 0xffffff;
	s->fill_colour2 = rnd() & 0xffffff;
	if (rnd() & 1) {
		s->box_shadow = rrange(-40, 40) * PLOT_STYLE_SCALE +
				(int)(rnd() % PLOT_STYLE_SCALE);
		s->box_shadow_y = rrange(-40, 40) * PLOT_STYLE_SCALE +
				  (int)(rnd() % PLOT_STYLE_SCALE);
		if (rnd() % 4 == 0)
			s->box_shadow_y = 0;
		s->box_shadow_inset = rnd() & 1;
		s->box_shadow_color = (rnd() & 1) ? (rnd() & 0xffffff) : 0;
	}
	if (rnd() % 10 < 7)
		s->opacity = (plot_style_fixed)(rnd() % 1200);
	switch (rnd() % 4) {
	case 0: s->transform = 0; break;
	case 1: s->transform = (int)((uint32_t)(rrange(-720, 720) * 64) << 16); break;
	case 2: s->transform = (int)(((uint32_t)(rrange(0, 359) * 64) << 16) |
				     ((uint32_t)(rnd() & 0xff) << 8) |
				     (rnd() & 0xff) | ((rnd() & 1) ? 0x80000000u : 0));
		break;
	default: s->transform = (int)rnd() ^ (int)(rnd() << 16); break;
	}
	switch (rnd() % 3) {
	case 0: s->transform_b = 0; break;
	case 1: s->transform_b = (int)0x01000100; break;
	default: s->transform_b = (int)(((uint32_t)rrange(0, 1024) << 16) |
					(uint32_t)rrange(0, 1024));
		break;
	}
	r->x0 = rrange(-100, 1000);
	r->y0 = rrange(-100, 600);
	r->x1 = r->x0 + rrange(-20, 600);
	r->y1 = r->y0 + rrange(-20, 400);
}

static void test_contract(void)
{
	struct { const char *name; plot_style_t s; struct rect r; } c[24];
	int n = 0, i;
	plot_style_t s;

	/* Hand cases: each one a verified probe from 06 §6c-6e. */
#define ADD(nm, rx0, ry0, rx1, ry1) do { c[n].name = nm; c[n].s = s; \
	c[n].r.x0 = rx0; c[n].r.y0 = ry0; c[n].r.x1 = rx1; c[n].r.y1 = ry1; n++; } while (0)
	s = style0(); ADD("solid", 10, 10, 110, 50);
	s = style0(); s.fill_type = PLOT_OP_TYPE_NONE; ADD("fill none", 10, 10, 110, 50);
	s = style0(); s.fill_type = PLOT_OP_TYPE_LINEAR_GRADIENT;
	s.fill_colour = 0x0000ff; s.fill_colour2 = 0xff0000; ADD("vgrad", 10, 10, 210, 170);
	s.fill_type = PLOT_OP_TYPE_LINEAR_GRADIENT_H; ADD("hgrad", 10, 10, 210, 170);
	ADD("hgrad narrow", 10, 10, 20, 170);
	ADD("hgrad empty span", 10, 10, 10, 170);
	s.fill_type = PLOT_OP_TYPE_RADIAL_GRADIENT; ADD("radial", 10, 10, 210, 170);
	s = style0(); s.box_shadow = 8 << 10; s.box_shadow_y = 8 << 10;
	ADD("drop 8,8", 10, 10, 210, 90);
	s.box_shadow = 40 << 10; ADD("drop clamp", 10, 10, 210, 90);
	s = style0(); s.box_shadow = 6 << 10; s.box_shadow_y = 6 << 10;
	s.box_shadow_inset = true; ADD("inset 6,6", 10, 90, 210, 170);
	s.box_shadow = -6 * PLOT_STYLE_SCALE; s.box_shadow_y = -500 * PLOT_STYLE_SCALE;
	s.box_shadow_color = 0x333333; ADD("inset neg clamp", 10, 90, 210, 170);
	s = style0(); s.transform = (90 << 6) << 16; s.transform_b = (int)0x01000100;
	ADD("rotate90", 10, 10, 110, 50);
	s = style0(); s.transform_b = (int)0x00800080; ADD("scale 0.5", 10, 10, 110, 50);
	s = style0(); s.transform = (30 << 6) << 16; ADD("rotate30", 10, 10, 110, 50);
	s = style0(); s.transform = 0x00000a05; ADD("translate", 10, 10, 110, 50);
	s = style0(); s.transform = (int)0x80000a05; ADD("pct translate", 10, 10, 110, 50);
	s = style0(); s.opacity = (PLOT_STYLE_SCALE * 40) / 100; ADD("opacity 40%", 10, 50, 110, 90);
	s.opacity = (PLOT_STYLE_SCALE * 90) / 100; ADD("opacity 90%", 10, 50, 110, 90);
	s.opacity = (PLOT_STYLE_SCALE * 3) / 100; ADD("opacity 3%", 10, 50, 110, 90);
	s = style0(); s.transform = (90 << 6) << 16;
	s.opacity = (PLOT_STYLE_SCALE * 40) / 100; ADD("rotate90+40%", 10, 10, 110, 50);
#undef ADD
	for (i = 0; i < n; i++)
		CHECK(contract_same(&c[i].s, &c[i].r, 1),
		      "contract: %s differs from monkey", c[i].name);

	/* Seeded fuzz over every field monkey_plot_rectangle reads. */
	{
		int fuzz = 200000, bad = 0;
		plot_style_t fs;
		struct rect fr;
		for (i = 0; i < fuzz; i++) {
			random_style(&fs, &fr);
			if (!contract_same(&fs, &fr, bad == 0)) {
				if (bad == 0)
					printf("  first fuzz mismatch at case %d\n", i);
				bad++;
			}
		}
		CHECK(bad == 0, "contract fuzz: %d/%d cases differ", bad, fuzz);
		printf("contract: %d hand cases + %d fuzz cases compared to monkey\n",
		       n, fuzz);
	}
}

/* --- B. backend ----------------------------------------------------- */

static unsigned int count_lines(const char *prefix)
{
	unsigned int k = 0;
	const char *p = vlog;
	size_t pl = strlen(prefix);

	while (*p) {
		if (strncmp(p, prefix, pl) == 0)
			k++;
		p = strchr(p, '\n');
		if (p == NULL)
			break;
		p++;
	}
	return k;
}

/** Does the log contain `line` as a whole line? */
static int has_line(const char *line)
{
	char needle[512];

	snprintf(needle, sizeof(needle), "%s\n", line);
	if (strncmp(vlog, needle, strlen(needle)) == 0)
		return 1;
	snprintf(needle, sizeof(needle), "\n%s\n", line);
	return strstr(vlog, needle) != NULL;
}

/** Index of the first log line starting with `prefix`, or -1. */
static int line_index(const char *prefix)
{
	int k = 0;
	const char *p = vlog;
	size_t pl = strlen(prefix);

	while (*p) {
		if (strncmp(p, prefix, pl) == 0)
			return k;
		p = strchr(p, '\n');
		if (p == NULL)
			break;
		p++;
		k++;
	}
	return -1;
}

static void full_clip(void)
{
	struct rect clip = { 0, 0, 960, 544 };
	P->clip(&ctx, &clip);
	vlog_reset();
}

static void test_backend(void)
{
	plot_style_t s;
	struct rect r;

	P = vita_plotters;
	CHECK(vita_plot_init() == NSERROR_OK, "vita_plot_init");
	CHECK(P->option_knockout, "knockout must match monkey's (stream order)");

	/* Colour: NetSurf 0xBBGGRR maps straight onto RGBA8's low bytes. */
	CHECK(vita_plot_rgba(0x00ff8040, VITA_BUCKET_SOLID) == (unsigned int)RGBA8(0x40, 0x80, 0xff, 255),
	      "rgba solid: %08x", vita_plot_rgba(0x00ff8040, VITA_BUCKET_SOLID));
	CHECK(vita_plot_rgba(0x01123456, 2) == (unsigned int)RGBA8(0x56, 0x34, 0x12, 128),
	      "rgba bucket 2 drops NS_TRANSPARENT and sets alpha 128");
	CHECK((vita_plot_rgba(0, 1) >> 24) == 64 && (vita_plot_rgba(0, 3) >> 24) == 191,
	      "bucket alphas 25%%/75%%");

	/* Solid rect: one call, exact geometry. */
	full_clip();
	s = style0(); s.fill_colour = 0x0000ff;
	r = (struct rect){ 10, 10, 110, 50 };
	P->rectangle(&ctx, &s, &r);
	CHECK(vcalls == 1 && has_line("rect 10 10 100 40 #ff0000ff"),
	      "solid rect:\n%s", vlog);

	/* Vertical gradient red->blue: 32 bands, exact first/last colours. */
	full_clip();
	s = style0(); s.fill_type = PLOT_OP_TYPE_LINEAR_GRADIENT;
	s.fill_colour = 0x0000ff; s.fill_colour2 = 0xff0000;
	r = (struct rect){ 10, 10, 210, 170 };
	P->rectangle(&ctx, &s, &r);
	CHECK(count_lines("rect ") == 32, "vgrad bands: %u", count_lines("rect "));
	CHECK(has_line("rect 10 10 200 5 #ff0000ff"), "vgrad first band:\n%.200s", vlog);
	/* band 31: t = 31*255/32 = 247 -> r = 255-247 = 8, b = 247 */
	CHECK(has_line("rect 10 165 200 5 #fff70008"), "vgrad last band");

	/* Horizontal gradient: vertical strips. */
	full_clip();
	s.fill_type = PLOT_OP_TYPE_LINEAR_GRADIENT_H;
	P->rectangle(&ctx, &s, &r);
	CHECK(count_lines("rect ") == 32 && has_line("rect 10 10 6 160 #ff0000ff"),
	      "hgrad strips:\n%.200s", vlog);

	/* Opacity buckets: 40% -> alpha 128; 3% -> nothing drawn. */
	full_clip();
	s = style0(); s.fill_colour = 0x00ff00;
	s.opacity = (PLOT_STYLE_SCALE * 40) / 100;
	r = (struct rect){ 10, 50, 110, 90 };
	P->rectangle(&ctx, &s, &r);
	CHECK(has_line("rect 10 50 100 40 #8000ff00"), "opacity 40%%:\n%s", vlog);
	full_clip();
	s.opacity = (PLOT_STYLE_SCALE * 3) / 100;
	P->rectangle(&ctx, &s, &r);
	CHECK(vcalls == 0, "opacity 3%% must not draw:\n%s", vlog);

	/* rotate(90): one 4-vertex triangle fan with the stream's corners. */
	full_clip();
	s = style0(); s.fill_colour = 0x0000ff;
	s.transform = (90 << 6) << 16; s.transform_b = (int)0x01000100;
	r = (struct rect){ 10, 10, 110, 50 };
	P->rectangle(&ctx, &s, &r);
	/* Its corners reach y = -20, across the screen-sized clip's top edge,
	 * so the stencil clips it: set once, then switched on. */
	CHECK(has_line("fan 4 80,-20 80,80 40,80 40,-20 #ff0000ff") &&
	      line_index("clip 0 0 960 544") >= 0 &&
	      line_index("clip-on") < line_index("fan 4 80,-20 80,80 40,80 40,-20 #ff0000ff"),
	      "rotate90 fan (crosses the clip: stencil first):\n%s", vlog);
	/* ...and with 40% opacity the fan carries alpha 128. */
	full_clip();
	s.opacity = (PLOT_STYLE_SCALE * 40) / 100;
	P->rectangle(&ctx, &s, &r);
	CHECK(has_line("fan 4 80,-20 80,80 40,80 40,-20 #800000ff"), "rotate90+40%%:\n%s", vlog);

	/* Drop shadow: MacSurf 50%% grey by default, painted BEFORE the fill. */
	full_clip();
	s = style0(); s.fill_colour = 0xffffff;
	s.box_shadow = 8 << 10; s.box_shadow_y = 8 << 10;
	r = (struct rect){ 10, 10, 210, 90 };
	P->rectangle(&ctx, &s, &r);
	CHECK(line_index("rect 18 18 200 80 #ff666666") == 0 &&
	      line_index("rect 10 10 200 80 #ffffffff") == 1,
	      "drop shadow then fill:\n%s", vlog);
	full_clip();
	s.box_shadow_color = 0x102030;
	P->rectangle(&ctx, &s, &r);
	CHECK(line_index("rect 18 18 200 80 #ff102030") == 0, "drop shadow colour:\n%s", vlog);

	/* Inset shadow: with no colour MacSurf skips it (stream still records
	 * the bands); with a colour, two bands AFTER the fill. */
	full_clip();
	s = style0(); s.fill_colour = 0xffffff;
	s.box_shadow = 6 << 10; s.box_shadow_y = 6 << 10; s.box_shadow_inset = true;
	r = (struct rect){ 10, 90, 210, 170 };
	P->rectangle(&ctx, &s, &r);
	CHECK(vcalls == 1, "colour-0 inset paints only the fill:\n%s", vlog);
	full_clip();
	s.box_shadow_color = 0x404040;
	P->rectangle(&ctx, &s, &r);
	CHECK(vcalls == 3 && line_index("rect 10 90 200 80 #ffffffff") == 0 &&
	      line_index("rect 10 90 6 80 #ff404040") == 1 &&
	      line_index("rect 10 90 200 6 #ff404040") == 2,
	      "inset bands after fill:\n%s", vlog);

	/* Stroke-only rect: no fill (stream still has the RECT), 4 edges. */
	full_clip();
	s = style0(); s.fill_type = PLOT_OP_TYPE_NONE;
	s.stroke_type = PLOT_OP_TYPE_SOLID; s.stroke_colour = 0x000000;
	s.stroke_width = 2 << 10;
	r = (struct rect){ 10, 10, 110, 50 };
	P->rectangle(&ctx, &s, &r);
	CHECK(vcalls == 4 && has_line("rect 10 10 100 2 #ff000000") &&
	      has_line("rect 108 12 2 36 #ff000000"), "stroke rect:\n%s", vlog);

	/* Clipping, CPU mode (the default since hardware run 4). A clip only
	 * records the rectangle, clamped to the screen; it costs the GPU
	 * nothing until a primitive crosses it. Each frame starts clean. */
	vita_plot_frame_begin();
	vlog_reset();
	r = (struct rect){ -5, 20, 2000, 300 };
	P->clip(&ctx, &r);
	CHECK(vcalls == 0, "cpu clip: setting a clip draws nothing:\n%s", vlog);
	s = style0(); s.fill_colour = 0x0000ff;
	r = (struct rect){ 0, 0, 100, 100 };
	P->rectangle(&ctx, &s, &r);
	CHECK(vcalls == 1 && has_line("rect 0 20 100 80 #ff0000ff"),
	      "cpu clip: a fill crossing the clip is cut on the CPU:\n%s", vlog);
	vlog_reset();
	r = (struct rect){ 0, 400, 100, 500 };
	P->rectangle(&ctx, &s, &r);
	CHECK(vcalls == 0, "cpu clip: a fill wholly outside is skipped:\n%s", vlog);
	vlog_reset();
	{
		int in[6] = { 10, 30, 50, 30, 30, 60 };		/* inside */
		int across[6] = { 10, 10, 50, 30, 30, 60 };	/* crosses y=20 */
		P->polygon(&ctx, &s, in, 3);
		CHECK(vcalls == 1 && line_index("fan 3") == 0,
		      "cpu clip: a fan inside the clip needs no stencil:\n%s", vlog);
		vlog_reset();
		P->polygon(&ctx, &s, across, 3);
		P->polygon(&ctx, &s, across, 3);
		CHECK(count_lines("clip 0 20 960 300") == 1 &&
		      count_lines("clip-on") == 1 && count_lines("fan 3") == 2,
		      "cpu clip: crossing fans set the stencil once, not per "
		      "primitive:\n%s", vlog);
		vlog_reset();
		P->polygon(&ctx, &s, in, 3);
		CHECK(vcalls == 1, "cpu clip: an inside fan leaves a stencil that "
		      "contains it alone:\n%s", vlog);
	}
	vita_plot_frame_end();
	CHECK(has_line("clip-off"), "cpu clip: the frame ends with clipping "
	      "off, so vita2d_start_drawing() rewrites nothing:\n%s", vlog);

	/* Stencil mode: the first version's behaviour, kept for measuring
	 * against -- every clip rewrites the stencil. */
	vita_plot_clip_mode = VITA_CLIP_STENCIL;
	vlog_reset();
	r = (struct rect){ -5, 20, 2000, 300 };
	P->clip(&ctx, &r);
	CHECK(has_line("clip-on") && has_line("clip 0 20 960 300") &&
	      vita_plot_clip_stats.stencil_writes >= 2,
	      "stencil clip: clamped, and written per clip:\n%s", vlog);
	vita_plot_clip_mode = VITA_CLIP_CPU;
	vita_plot_frame_begin();
	vlog_reset();
	r = (struct rect){ 50, 50, 50, 80 };
	P->clip(&ctx, &r);
	s = style0();
	r = (struct rect){ 10, 10, 110, 50 };
	P->rectangle(&ctx, &s, &r);
	CHECK(vcalls == 0, "empty clip suppresses drawing:\n%s", vlog);

	/* Text: counted run -> NUL-terminated copy, baseline x/y, 16px. */
	full_clip();
	{
		plot_font_style_t f;
		memset(&f, 0, sizeof(f));
		f.size = 12 * PLOT_STYLE_SCALE;	/* 12pt = 16px at 96 dpi */
		f.foreground = 0x0000ff;
		P->text(&ctx, &f, 5, 30, "Hello, world", 5);
		CHECK(has_line("text 5 30 #ff0000ff 16px 'Hello'"), "text:\n%s", vlog);
		/* The core's weight reaches the engine: 700 is bold. */
		vlog_reset();
		f.weight = 700;
		P->text(&ctx, &f, 5, 30, "Bold", 4);
		CHECK(has_line("text 5 30 #ff0000ff 16px bold 'Bold'"),
		      "text: weight 700 is bold:\n%s", vlog);
	}

	/* Lines: 1px -> draw_line; thick horizontal -> exact rect. */
	full_clip();
	s = style0(); s.stroke_type = PLOT_OP_TYPE_SOLID; s.stroke_colour = 0x00ff00;
	s.stroke_width = 1 << 10;
	r = (struct rect){ 0, 5, 100, 5 };
	P->line(&ctx, &s, &r);
	s.stroke_width = 4 << 10;
	P->line(&ctx, &s, &r);
	CHECK(has_line("line 0 5 100 5 #ff00ff00") && has_line("rect 0 3 100 4 #ff00ff00"),
	      "lines:\n%s", vlog);

	/* Polygon -> fan; disc -> fill_circle. */
	full_clip();
	{
		int tri[6] = { 0, 0, 10, 0, 5, 8 };
		s = style0(); s.fill_colour = 0x000000;
		P->polygon(&ctx, &s, tri, 3);
		P->disc(&ctx, &s, 50, 60, 7);
		CHECK(has_line("fan 3 0,0 10,0 5,8 #ff000000") &&
		      has_line("circle 50 60 7 #ff000000"), "polygon/disc:\n%s", vlog);
	}

	/* Bitmap: scaled to the target box; X-repeat tiles across the clip. */
	{
		struct bitmap bm;
		bm.tex = vita2d_create_empty_texture(10, 20);
		full_clip();
		P->bitmap(&ctx, &bm, 100, 50, 20, 40, 0, BITMAPF_NONE);
		CHECK(vcalls == 1 && has_line("tex 10x20 100 50 2 2"), "bitmap:\n%s", vlog);
		r = (struct rect){ 0, 0, 100, 100 };
		P->clip(&ctx, &r);
		vlog_reset();
		P->bitmap(&ctx, &bm, 30, 0, 20, 40, 0, BITMAPF_REPEAT_X);
		CHECK(count_lines("tex ") == 6 && has_line("tex 10x20 -10 0 2 2"),
		      "repeat-x tiles:\n%s", vlog);
		vita2d_free_texture(bm.tex);
	}

	/* Plot-stream dump (the device-side diag format): every op written
	 * exactly as nsmonkey would, so device dumps diff against the
	 * desktop streams. The rectangle pieces must equal the real monkey
	 * plotter's lines for the same style. */
	{
		static char mbuf[8192], dbuf[8192];
		char expect[8192];
		size_t got;
		plot_font_style_t f;
		int tri[6] = { 0, 0, 10, 0, 5, 8 };

		vita_plot_trace = tmpfile();
		CHECK(vita_plot_trace != NULL, "tmpfile");
		r = (struct rect){ 1, 2, 300, 400 };
		P->clip(&ctx, &r);
		s = style0(); s.fill_type = PLOT_OP_TYPE_LINEAR_GRADIENT;
		s.box_shadow = 8 << 10; s.box_shadow_y = 8 << 10;
		s.opacity = (PLOT_STYLE_SCALE * 40) / 100;
		r = (struct rect){ 10, 10, 210, 170 };
		P->rectangle(&ctx, &s, &r);
		memset(&f, 0, sizeof(f));
		f.size = 12 * PLOT_STYLE_SCALE;
		P->text(&ctx, &f, 5, 30, "Hello, world", 5);
		P->polygon(&ctx, &s, tri, 3);
		rewind(vita_plot_trace);
		got = fread(dbuf, 1, sizeof(dbuf) - 1, vita_plot_trace);
		dbuf[got] = '\0';
		fclose(vita_plot_trace);
		vita_plot_trace = NULL;

		test_monkey_rectangle(&s, &r, mbuf, sizeof(mbuf));
		{
			/* monkey's lines come without the PLOT prefix */
			size_t n = 0;
			const char *m = mbuf;
			n += (size_t)snprintf(expect + n, sizeof(expect) - n,
				"PLOT CLIP X0 1 Y0 2 X1 300 Y1 400\n");
			while (*m) {
				size_t len = strcspn(m, "\n");
				n += (size_t)snprintf(expect + n, sizeof(expect) - n,
					"PLOT %.*s\n", (int)len, m);
				m += len + (m[len] == '\n');
			}
			snprintf(expect + n, sizeof(expect) - n,
				 "PLOT TEXT X 5 Y 30 STR Hello\n"
				 "PLOT POLYGON VERTICIES 3\n");
		}
		CHECK(strcmp(dbuf, expect) == 0,
		      "plot dump format:\n--- got\n%s--- expected\n%s", dbuf, expect);
	}

	vita_plot_fini();
}

/* --- C. stream replay ------------------------------------------------ */

static char *slurp(const char *path)
{
	FILE *f = fopen(path, "rb");
	long n;
	char *b;

	if (f == NULL)
		return NULL;
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	fseek(f, 0, SEEK_SET);
	b = malloc((size_t)n + 1);
	if (fread(b, 1, (size_t)n, f) != (size_t)n) {
		free(b);
		fclose(f);
		return NULL;
	}
	b[n] = '\0';
	fclose(f);
	return b;
}

/**
 * Independently derive the draw calls a stream must produce (geometry and
 * alpha only; replay colours are a palette), and compare in order.
 */
static int replay_matches(const char *stream, const char *name)
{
	char expect[1 << 16];
	size_t elen = 0;
	const char *p = stream;
	int cx0 = 0, cy0 = 0, cx1 = 960, cy1 = 544;
	const char *l;
	char got[1 << 16];
	size_t glen2 = 0;

	expect[0] = '\0';
	while (*p) {
		char line[1024];
		size_t len = strcspn(p, "\n");
		int a, b, c, d, bucket = 4;
		const char *op;
		memcpy(line, p, len < 1023 ? len : 1023);
		line[len < 1023 ? len : 1023] = '\0';
		p += len + (p[len] == '\n');
		op = strstr(line, " OPAQUE ");
		if (op)
			sscanf(op, " OPAQUE %d", &bucket);
		if (sscanf(line, "PLOT CLIP X0 %d Y0 %d X1 %d Y1 %d", &a, &b, &c, &d) == 4) {
			cx0 = a < 0 ? 0 : a; cy0 = b < 0 ? 0 : b;
			cx1 = c > 960 ? 960 : c; cy1 = d > 544 ? 544 : d;
		} else if (sscanf(line, "PLOT RECT X0 %d Y0 %d X1 %d Y1 %d", &a, &b, &c, &d) == 4) {
			/* CPU clipping: a fill arrives cut to the clip, or not at
			 * all if nothing of it is inside. */
			int ia = a > cx0 ? a : cx0, ib = b > cy0 ? b : cy0;
			int ic = c < cx1 ? c : cx1, id = d < cy1 ? d : cy1;
			if (cx1 > cx0 && cy1 > cy0 && bucket > 0 && ic > ia && id > ib)
				elen += (size_t)snprintf(expect + elen, sizeof(expect) - elen,
					"rect %d %d %d %d a%u\n", ia, ib, ic - ia, id - ib,
					(vita_plot_rgba(0, bucket) >> 24));
		} else if (strncmp(line, "PLOT POLY ", 10) == 0) {
			int x[4], y[4];
			int k, bx0, by0, bx1, by1;
			if (sscanf(line, "PLOT POLY X0 %d Y0 %d X1 %d Y1 %d X2 %d Y2 %d X3 %d Y3 %d",
				   &x[0], &y[0], &x[1], &y[1], &x[2], &y[2], &x[3], &y[3]) != 8)
				continue;
			bx0 = bx1 = x[0]; by0 = by1 = y[0];
			for (k = 1; k < 4; k++) {
				if (x[k] < bx0) bx0 = x[k];
				if (x[k] > bx1) bx1 = x[k];
				if (y[k] < by0) by0 = y[k];
				if (y[k] > by1) by1 = y[k];
			}
			/* A quad wholly outside the clip is skipped; one that
			 * reaches in is drawn whole and the stencil cuts it. */
			if (cx1 > cx0 && cy1 > cy0 && bucket > 0 &&
			    bx1 > cx0 && by1 > cy0 && bx0 < cx1 && by0 < cy1)
				elen += (size_t)snprintf(expect + elen, sizeof(expect) - elen,
					"fan 4 %d,%d %d,%d %d,%d %d,%d a%u\n",
					x[0], y[0], x[1], y[1], x[2], y[2], x[3], y[3],
					(vita_plot_rgba(0, bucket) >> 24));
		}
	}

	/* Reduce the log to the same shape: rect/fan lines, alpha only. */
	got[0] = '\0';
	for (l = vlog; *l; ) {
		size_t len = strcspn(l, "\n");
		if (strncmp(l, "rect ", 5) == 0 || strncmp(l, "fan ", 4) == 0) {
			const char *hash = memchr(l, '#', len);
			unsigned int rgba = 0;
			if (hash)
				sscanf(hash + 1, "%8x", &rgba);
			glen2 += (size_t)snprintf(got + glen2, sizeof(got) - glen2,
				"%.*s a%u\n", (int)(hash ? hash - l - 1 : (long)len), l,
				rgba >> 24);
		}
		l += len + (l[len] == '\n');
	}
	if (strcmp(expect, got) != 0) {
		printf("  %s: replay calls differ from stream\n", name);
		return 0;
	}
	return 1;
}

static unsigned int count_ops(const char *stream, const char *op)
{
	unsigned int k = 0;
	const char *p = stream;
	size_t ol = strlen(op);

	while (*p) {
		if (strncmp(p, op, ol) == 0)
			k++;
		p = strchr(p, '\n');
		if (p == NULL)
			break;
		p++;
	}
	return k;
}

static void replay_dir(const char *dir, unsigned int *files)
{
	DIR *d = opendir(dir);
	struct dirent *e;

	CHECK(d != NULL, "cannot open %s", dir);
	if (d == NULL)
		return;
	vita_plot_init();
	while ((e = readdir(d)) != NULL) {
		char path[1024];
		char *s;
		struct vita_replay_stats st;
		size_t nl = strlen(e->d_name);
		if (nl < 6 || strcmp(e->d_name + nl - 5, ".plot") != 0)
			continue;
		snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
		s = slurp(path);
		CHECK(s != NULL, "read %s", path);
		if (s == NULL)
			continue;
		memset(&st, 0, sizeof(st));
		vita_plot_set_clip(0, 0, 960, 544);
		vlog_reset();
		vita_replay_stream(s, &st);
		CHECK(st.rect == count_ops(s, "PLOT RECT ") &&
		      st.poly == count_ops(s, "PLOT POLY ") &&
		      st.clip == count_ops(s, "PLOT CLIP ") &&
		      st.text == count_ops(s, "PLOT TEXT ") &&
		      st.line == count_ops(s, "PLOT LINE "),
		      "%s: op counts rect %u clip %u text %u line %u poly %u",
		      e->d_name, st.rect, st.clip, st.text, st.line, st.poly);
		CHECK(st.text == count_lines("text "), "%s: every TEXT drawn", e->d_name);
		CHECK(replay_matches(s, e->d_name), "%s: replay geometry", e->d_name);
		printf("replay %-24s rect %3u poly %u clip %3u text %2u line %u -> %u vita2d calls\n",
		       e->d_name, st.rect, st.poly, st.clip, st.text, st.line, vcalls);
		(*files)++;
		free(s);
	}
	closedir(d);
	vita_plot_fini();
}

/* --- D. ink clip (patch 32) --------------------------------------------- */

/**
 * Find the first op in a stream whose text starts with `op` and return the
 * clip rectangle in force when it was plotted.
 */
static int clip_at_op(const char *stream, const char *op, struct rect *clip)
{
	const char *p = stream;
	size_t ol = strlen(op);

	clip->x0 = 0; clip->y0 = 0; clip->x1 = 960; clip->y1 = 544;
	while (*p) {
		struct rect c;
		if (sscanf(p, "PLOT CLIP X0 %d Y0 %d X1 %d Y1 %d",
			   &c.x0, &c.y0, &c.x1, &c.y1) == 4)
			*clip = c;
		else if (strncmp(p, op, ol) == 0)
			return 1;
		p = strchr(p, '\n');
		if (p == NULL)
			break;
		p++;
	}
	return 0;
}

/** Is a shadow/quad bbox fully inside the clip in force when drawn? */
static int ink_visible(const char *stream, const char *op, int x0, int y0,
		       int x1, int y1)
{
	struct rect c;
	if (!clip_at_op(stream, op, &c))
		return -1;
	return c.x0 <= x0 && c.y0 <= y0 && c.x1 >= x1 && c.y1 >= y1;
}

/*
 * The core clipped a box's drop shadow and transformed quad to the box
 * itself (09 §5). Patch 32 puts that ink in layout's descendant bbox and
 * widens the background-paint clip. Checked on the patched-engine captures,
 * which tools/check-patched-streams.sh keeps in step with the live engine.
 */
static void test_ink_clip(const char *root)
{
	char path[1024];
	char *s;

	snprintf(path, sizeof(path), "%s/testpages/patched-streams/PM-shadow.plot", root);
	s = slurp(path);
	CHECK(s != NULL && ink_visible(s, "PLOT RECT X0 18 Y0 18 X1 218 Y1 98",
				       18, 18, 218, 98) == 1,
	      "PM-shadow: 8px drop shadow fully inside its clip");
	free(s);

	snprintf(path, sizeof(path), "%s/testpages/patched-streams/PM-shadow-clip.plot", root);
	s = slurp(path);
	CHECK(s != NULL && ink_visible(s, "PLOT RECT X0 20 Y0 20 X1 220 Y1 80",
				       20, 20, 220, 80) == 1,
	      "PM-shadow-clip: last child's shadow survives the parent clip (part A)");
	CHECK(s != NULL && ink_visible(s, "PLOT RECT X0 20 Y0 110 X1 220 Y1 170",
				       20, 110, 220, 170) == 1,
	      "PM-shadow-clip: overflow:hidden box keeps its own shadow (part B)");
	CHECK(s != NULL && ink_visible(s, "PLOT RECT X0 310 Y0 20 X1 510 Y1 80",
				       310, 20, 510, 80) == 0,
	      "PM-shadow-clip: a CSS clip rect still clips the shadow (control)");
	free(s);

	snprintf(path, sizeof(path), "%s/testpages/patched-streams/PM-animation.plot", root);
	s = slurp(path);
	{
		struct rect c;
		/* rotate(90) quad spans y -20..80; the top is off-page, the
		 * bottom must not be cut at the box's own edge (y 50). */
		CHECK(s != NULL && clip_at_op(s, "PLOT POLY X0 80 Y0 -20", &c) &&
		      c.y1 >= 80 && c.x0 <= 40 && c.x1 >= 80,
		      "PM-animation: rotated quad's extent inside its clip");
	}
	free(s);
}

int main(int argc, char **argv)
{
	const char *root = argc > 1 ? argv[1] : ".";
	char dir[1024];
	unsigned int files = 0;

	test_contract();
	test_backend();
	snprintf(dir, sizeof(dir), "%s/testpages/golden", root);
	replay_dir(dir, &files);
	snprintf(dir, sizeof(dir), "%s/testpages/patched-streams", root);
	replay_dir(dir, &files);
	CHECK(files >= 9, "expected >= 9 stream files, replayed %u", files);
	test_ink_clip(root);

	printf("\n%d/%d checks passed\n", run - failed, run);
	return failed ? 1 : 0;
}
