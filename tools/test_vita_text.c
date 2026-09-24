/* Host-side test of the Vita frontend's text engine (frontends/vita/text.c).
 *
 * The real engine, the real fonts (tools/fetch-fonts.sh), and a vita2d
 * stand-in whose textures are real memory, so what text.c writes into its
 * atlas can be inspected. What is checked is what hardware run 3 showed
 * the system PGF font getting wrong (docs/phase-0/10-hardware-test-plan.md):
 *
 *  - coverage: Greek with accents, Cyrillic, kana, kanji, simplified
 *    Chinese and Hangul each resolve to a face that has them;
 *  - agreement: every glyph is drawn exactly one advance after the last,
 *    the advances layout measures with;
 *  - no bleed: glyphs are rendered at the exact size (no scaling), never
 *    overlap in the atlas, and every glyph has an empty 1-pixel border in
 *    the texture itself;
 *  - the atlas cache and its between-frames reset.
 *
 * Build and run: tools/test-vita-renderer.sh (after tools/fetch-fonts.sh)
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vita2d.h>

#include "utils/utf8.h"
#include "utils/log.h"
#include "vita/text.h"

/* ---- what text.c needs from the core ---------------------------------- */

uint32_t utf8_to_ucs4(const char *s, size_t l)
{
	const unsigned char *p = (const unsigned char *)s;
	uint32_t c = p[0];
	size_t n = 0, k;

	if (c >= 0xf0 && l >= 4) { c &= 0x07; n = 3; }
	else if (c >= 0xe0 && l >= 3) { c &= 0x0f; n = 2; }
	else if (c >= 0xc0 && l >= 2) { c &= 0x1f; n = 1; }
	for (k = 1; k <= n; k++)
		c = (c << 6) | (p[k] & 0x3f);
	return c;
}

size_t utf8_next(const char *s, size_t l, size_t o)
{
	o++;
	while (o < l && ((unsigned char)s[o] & 0xc0) == 0x80)
		o++;
	return o;
}

void nslog_log(const char *file, const char *func, int ln,
	       const char *format, ...)
{
	va_list ap;
	(void)file; (void)func; (void)ln;
	va_start(ap, format);
	vfprintf(stdout, format, ap);
	va_end(ap);
	fputc('\n', stdout);
}

/* vita/diag.c stand-in: text.c logs face failures there. */
void vita_diag_log(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
	fputc('\n', stdout);
}

/* ---- vita2d stand-in --------------------------------------------------- */

#define MAX_DRAWS 4096
static struct draw {
	const vita2d_texture *t;
	int x, y, tx, ty, tw, th;
} draws[MAX_DRAWS];
static int ndraws;
static int waits;

vita2d_texture *vita2d_create_empty_texture_format(unsigned int w,
		unsigned int h, SceGxmTextureFormat format)
{
	vita2d_texture *t = calloc(1, sizeof(*t));
	(void)format;
	t->w = w;
	t->h = h;
	t->stride = (w + 7) & ~7u;
	t->alpha8 = 1;
	/* Not zeroed: text.c must clear its own atlas pages. */
	t->data = malloc((size_t)t->stride * h);
	memset(t->data, 0xa5, (size_t)t->stride * h);
	return t;
}
vita2d_texture *vita2d_create_empty_texture(unsigned int w, unsigned int h)
{
	return vita2d_create_empty_texture_format(w, h,
					SCE_GXM_TEXTURE_FORMAT_U8_R111);
}
void vita2d_free_texture(vita2d_texture *t)
{
	free(t->data);
	free(t);
}
unsigned int vita2d_texture_get_stride(const vita2d_texture *t) { return t->stride; }
void *vita2d_texture_get_datap(const vita2d_texture *t) { return t->data; }
void vita2d_texture_set_filters(vita2d_texture *t, SceGxmTextureFilter a,
				SceGxmTextureFilter b)
{
	(void)t;
	if (a != SCE_GXM_TEXTURE_FILTER_POINT || b != SCE_GXM_TEXTURE_FILTER_POINT)
		printf("FAIL: atlas not point-sampled\n");
}
void vita2d_wait_rendering_done(void) { waits++; }
void vita2d_draw_texture_tint_part(const vita2d_texture *t, float x, float y,
				   float tx, float ty, float tw, float th,
				   unsigned int color)
{
	(void)color;
	if (ndraws < MAX_DRAWS)
		draws[ndraws++] = (struct draw){ t, (int)x, (int)y, (int)tx,
						 (int)ty, (int)tw, (int)th };
}

unsigned int vita2d_texture_get_width(const vita2d_texture *t) { return t->w; }
unsigned int vita2d_texture_get_height(const vita2d_texture *t) { return t->h; }

/* The per-frame vertex pool: never reset here, only ever a few runs. */
void *vita2d_pool_memalign(unsigned int size, unsigned int alignment)
{
	static unsigned char pool[4 << 20];
	static size_t used;
	void *p;

	used = (used + alignment - 1) / alignment * alignment;
	if (used + size > sizeof(pool))
		used = 0;
	p = pool + used;
	used += size;
	return p;
}

/* Batched glyphs (text.c draw_placed): each quad is 6 vertices, two
 * triangles 0 1 2 / 2 1 3 of a tint_part strip. Decoded back into the same
 * records tint_part makes, so every check below also checks the vertex
 * math -- and the two triangles must really make that rectangle. */
void vita2d_draw_array_textured(const vita2d_texture *t,
				SceGxmPrimitiveType mode,
				const vita2d_texture_vertex *v, size_t count,
				unsigned int color)
{
	size_t k;

	(void)color;
	if (mode != SCE_GXM_PRIMITIVE_TRIANGLES || count % 6 != 0)
		printf("FAIL: batched glyphs not whole triangle pairs\n");
	for (k = 0; k + 5 < count; k += 6) {
		const vita2d_texture_vertex *q = &v[k];
		float w = (float)t->w, h = (float)t->h;
		if (q[1].x != q[4].x || q[1].y != q[4].y ||
		    q[2].x != q[3].x || q[2].y != q[3].y ||
		    q[0].x != q[2].x || q[0].y != q[1].y ||
		    q[5].x != q[1].x || q[5].y != q[2].y)
			printf("FAIL: batched glyph is not a rectangle\n");
		if (ndraws < MAX_DRAWS)
			draws[ndraws++] = (struct draw){ t, (int)q[0].x,
				(int)q[0].y, (int)(q[0].u * w + 0.5f),
				(int)(q[0].v * h + 0.5f),
				(int)((q[5].u - q[0].u) * w + 0.5f),
				(int)((q[5].v - q[0].v) * h + 0.5f) };
	}
}

/* ---- harness ----------------------------------------------------------- */

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

static const char *face_of(const struct vita_text_style *s, uint32_t cp)
{
	const char *f = vita_text_face_name(s, cp);
	return f != NULL ? f : "(missing)";
}

/** Every glyph in `utf8` drawn one advance after the previous one? */
static int draws_follow_advances(const struct vita_text_style *s,
				 const char *utf8)
{
	size_t len = strlen(utf8), i = 0;
	int k, pen = 0, first_x;

	ndraws = 0;
	vita_text_draw(s, 100, 200, utf8, len, 0xff000000);
	if (ndraws == 0)
		return 0;
	/* Same glyph repeated: each draw is exactly one advance further. */
	first_x = draws[0].x;
	for (k = 0; k < ndraws && i < len; k++) {
		if (draws[k].x != first_x + pen)
			return 0;
		pen += vita_text_advance(s, utf8_to_ucs4(utf8 + i, len - i));
		i = utf8_next(utf8, len, i);
	}
	return k == ndraws;
}

/** No two drawn atlas rects overlap, even grown by the 1-pixel gap, and
 * the texels in each rect's 1-pixel border are all empty. */
static int atlas_clean(void)
{
	int a, b, i;

	for (a = 0; a < ndraws; a++) {
		const struct draw *d = &draws[a];
		const vita2d_texture *t = d->t;
		for (b = a + 1; b < ndraws; b++) {
			const struct draw *e = &draws[b];
			if (e->t != t || (e->tx == d->tx && e->ty == d->ty))
				continue;	/* other page, or the same glyph */
			if (e->tx < d->tx + d->tw + 1 && d->tx < e->tx + e->tw + 1 &&
			    e->ty < d->ty + d->th + 1 && d->ty < e->ty + e->th + 1)
				return 0;
		}
		for (i = -1; i <= d->tw; i++) {
			int x = d->tx + i;
			if (x < 0 || x >= (int)t->w)
				continue;
			if ((d->ty > 0 && t->data[(d->ty - 1) * t->stride + x]) ||
			    (d->ty + d->th < (int)t->h &&
			     t->data[(d->ty + d->th) * t->stride + x]))
				return 0;
		}
		for (i = -1; i <= d->th; i++) {
			int y = d->ty + i;
			if (y < 0 || y >= (int)t->h)
				continue;
			if ((d->tx > 0 && t->data[y * t->stride + d->tx - 1]) ||
			    (d->tx + d->tw < (int)t->w &&
			     t->data[y * t->stride + d->tx + d->tw]))
				return 0;
		}
	}
	return 1;
}

int main(int argc, char **argv)
{
	char dir[1024];
	struct vita_text_style s, b, it, serif, mono;
	unsigned int r0;
	int i, w;

	snprintf(dir, sizeof(dir), "%s/", argc > 1 ? argv[1] : "fonts");
	CHECK(vita_text_init(dir) == NSERROR_OK, "init with fonts in %s", dir);

	vita_text_style_default(&s, 16);

	/* Coverage: the run-3 failures, and where each now comes from. */
	CHECK(!strcmp(face_of(&s, 0x41), "DejaVuSans.ttf"), "A: %s", face_of(&s, 0x41));
	CHECK(!strcmp(face_of(&s, 0x3ac), "DejaVuSans.ttf"),
	      "Greek alpha-tonos (was missing): %s", face_of(&s, 0x3ac));
	CHECK(!strcmp(face_of(&s, 0x41a), "DejaVuSans.ttf"),
	      "Cyrillic (was full-width Japanese): %s", face_of(&s, 0x41a));
	CHECK(!strcmp(face_of(&s, 0x3072), "DroidSansFallbackFull.ttf"),
	      "hiragana: %s", face_of(&s, 0x3072));
	CHECK(!strcmp(face_of(&s, 0x65e5), "DroidSansFallbackFull.ttf"),
	      "kanji: %s", face_of(&s, 0x65e5));
	CHECK(!strcmp(face_of(&s, 0x7b80), "DroidSansFallbackFull.ttf"),
	      "simplified jian (was missing): %s", face_of(&s, 0x7b80));
	CHECK(!strcmp(face_of(&s, 0xd55c), "NanumGothic-Regular.ttf"),
	      "Hangul (was blank): %s", face_of(&s, 0xd55c));
	CHECK(vita_text_face_name(&s, 0xe000) == NULL &&
	      vita_text_advance(&s, 0xe000) > 0 && vita_text_stats.missing > 0,
	      "a code point nobody has: missing, but takes room (a box)");
	/* Greek is no longer full-width: an alpha is narrower than a kanji. */
	CHECK(vita_text_advance(&s, 0x3b1) < vita_text_advance(&s, 0x65e5),
	      "Greek alpha %d px vs kanji %d px", vita_text_advance(&s, 0x3b1),
	      vita_text_advance(&s, 0x65e5));

	/* Styles pick real faces. */
	b = s; b.bold = true;
	it = s; it.italic = true;
	serif = s; serif.family = VITA_FAMILY_SERIF; serif.italic = true;
	mono = s; mono.family = VITA_FAMILY_MONO;
	CHECK(!strcmp(face_of(&b, 'A'), "DejaVuSans-Bold.ttf"), "bold: %s", face_of(&b, 'A'));
	CHECK(!strcmp(face_of(&it, 'A'), "DejaVuSans-Oblique.ttf"), "italic: %s", face_of(&it, 'A'));
	CHECK(!strcmp(face_of(&serif, 'A'), "DejaVuSerif-Italic.ttf"), "serif italic: %s", face_of(&serif, 'A'));
	CHECK(!strcmp(face_of(&mono, 'A'), "DejaVuSansMono.ttf"), "mono: %s", face_of(&mono, 'A'));
	CHECK(vita_text_advance(&b, 'm') > vita_text_advance(&s, 'm'),
	      "bold is wider: %d vs %d", vita_text_advance(&b, 'm'),
	      vita_text_advance(&s, 'm'));
	for (i = 0x21, w = vita_text_advance(&mono, 0x20); i < 0x7f; i++)
		if (vita_text_advance(&mono, (uint32_t)i) != w)
			break;
	CHECK(i == 0x7f, "monospace: every ASCII advance is %d (U+%02X differs)", w, i);

	/* Layout and drawing agree: width is the sum of advances, and every
	 * glyph is drawn exactly one advance after the previous. */
	{
		const char *t = "The quick brown fox \xce\xac\xce\xbb \xe6\x97\xa5\xed\x95\x9c";
		size_t len = strlen(t), k = 0;
		int sum = 0;
		while (k < len) {
			sum += vita_text_advance(&s, utf8_to_ucs4(t + k, len - k));
			k = utf8_next(t, len, k);
		}
		CHECK(vita_text_width(&s, t, len) == sum,
		      "width %d == sum of advances %d", vita_text_width(&s, t, len), sum);
		ndraws = 0;
		CHECK(vita_text_draw(&s, 10, 50, t, len, 0xff000000) == sum,
		      "draw returns the measured width");
	}
	CHECK(draws_follow_advances(&s, "iiiiiiii"), "iiii drawn one advance apart");
	CHECK(draws_follow_advances(&s, "WWWW"), "WWWW drawn one advance apart");
	CHECK(draws_follow_advances(&s, "\xe6\x97\xa5\xe6\x97\xa5\xe6\x97\xa5"),
	      "kanji drawn one advance apart");
	CHECK(draws_follow_advances(&s, "\xed\x95\x9c\xed\x95\x9c"),
	      "Hangul drawn one advance apart");

	/* Exact size: 17 px is rendered afresh, not scaled from 16 px; a
	 * repeat is served from the atlas. */
	r0 = vita_text_stats.rasterised;
	ndraws = 0;
	vita_text_draw(&s, 0, 20, "Hg", 2, 0xff000000);
	CHECK(vita_text_stats.rasterised == r0 + 2, "Hg at 16 px rendered once");
	vita_text_draw(&s, 0, 20, "Hg", 2, 0xff000000);
	CHECK(vita_text_stats.rasterised == r0 + 2 && vita_text_stats.atlas_hits > 0,
	      "Hg again: from the atlas");
	{
		struct vita_text_style s17 = s;
		s17.px = 17;
		vita_text_draw(&s17, 0, 20, "Hg", 2, 0xff000000);
		CHECK(vita_text_stats.rasterised == r0 + 4,
		      "Hg at 17 px rendered, not scaled");
		CHECK(draws[ndraws - 1].th != draws[1].th ||
		      draws[ndraws - 1].tw != draws[1].tw,
		      "17 px glyph has its own size in the atlas");
	}

	/* No bleed: a page of mixed glyphs, then the atlas inspected. */
	ndraws = 0;
	{
		const char *mix = "Caf\xc3\xa9 fa\xc3\xa7" "ade dash \xe2\x80\x94 "
			"Japanese \xe6\x97\xa5\xe6\x9c\xac Chinese \xe7\xae\x80 "
			"\xce\x95\xce\xbb\xce\xbb\xce\xb7\xce\xbd\xce\xb9\xce\xba\xce\xac";
		vita_text_draw(&s, 0, 100, mix, strlen(mix), 0xff000000);
		vita_text_draw(&b, 0, 130, mix, strlen(mix), 0xff000000);
	}
	CHECK(ndraws > 40 && atlas_clean(),
	      "%d glyphs: no overlaps, every glyph's 1-px border empty", ndraws);

	/* Filling the atlas: glyphs are dropped until the next frame, which
	 * resets it (after waiting for the GPU) instead of overwriting glyphs
	 * the GPU may still be drawing. */
	{
		struct vita_text_style big;
		char buf[8];
		uint32_t cp;
		vita_text_style_default(&big, 180);
		for (cp = 0x4e00; cp < 0x4e00 + 300; cp++) {
			buf[0] = (char)(0xe0 | (cp >> 12));
			buf[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
			buf[2] = (char)(0x80 | (cp & 0x3f));
			vita_text_draw(&big, 0, 200, buf, 3, 0xff000000);
		}
		CHECK(vita_text_stats.dropped > 0 && vita_text_stats.flushes == 0,
		      "atlas full: %u glyphs dropped, not overwritten mid-frame",
		      vita_text_stats.dropped);
		i = waits;
		vita_text_frame_begin();
		CHECK(vita_text_stats.flushes == 1 && waits == i + 1,
		      "next frame: atlas reset once, after waiting for the GPU");
		r0 = vita_text_stats.rasterised;
		ndraws = 0;
		vita_text_draw(&s, 0, 20, "Hg", 2, 0xff000000);
		CHECK(vita_text_stats.rasterised == r0 + 2 && ndraws == 2 &&
		      atlas_clean(), "after the reset glyphs render again, cleanly");
	}

	printf("atlas: %u pages, %u rasterised, %u hits, %u flushes, %u dropped\n",
	       vita_text_stats.atlas_pages, vita_text_stats.rasterised,
	       vita_text_stats.atlas_hits, vita_text_stats.flushes,
	       vita_text_stats.dropped);
	vita_text_fini();
	printf("\n%d/%d checks passed\n", run - failed, run);
	return failed ? 1 : 0;
}
