/* Host simulator of the vitaSDK surface that frontends/vita uses.
 *
 * Links under the real Vita frontend (built with VITA_HOST_SIM=YES, see
 * tools/run-vita-sim.sh) in place of libvita2d and the SceCtrl / kernel
 * stubs, so the unmodified frontend -- main loop, window, file-path table,
 * PGF layout, bitmaps, plotters -- runs the real patched engine on the
 * build machine:
 *
 *  - vita2d draw calls are rasterised into a 960x544 RGBA frame with the
 *    GPU's pixel-centre coverage rule and straight-alpha blending, honouring
 *    the clip rectangle;
 *  - "PGF" text is FreeType (VITA_SIM_FONT, default DejaVu Sans) at
 *    scale x VITA_PGF_EM_PX pixels, drawn with its baseline at y. Layout
 *    measures with the same face, so line breaks are real;
 *  - input is scripted: once the screen has been idle for a while (the page
 *    has settled) the last shown frame is written to VITA_SIM_OUT/page-N.png
 *    and R is pressed to open the next test page; after VITA_SIM_PAGES
 *    pages, START quits.
 *
 * What this cannot tell you: anything about the GXM, PGF's real metrics,
 * memory, or speed. It proves the frontend's logic, not the hardware.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>

#include <zlib.h>
#include <ft2build.h>
#include FT_FREETYPE_H

#include <vita2d.h>
#include <psp2/ctrl.h>
#include <psp2/kernel/processmgr.h>
#include <psp2/kernel/threadmgr.h>

#define W 960
#define H 544
/* Must match VITA_PGF_EM_PX in frontends/vita/plot.c. */
#define PGF_EM_PX 20.0f

static uint32_t back[W * H];	/* frame being drawn, RGBA8 as vita2d packs */
static uint32_t shown[W * H];	/* last swapped frame */
static uint32_t clear_color = 0xff000000;
static unsigned int sim_failures;
static int clip_on;
static int cx0, cy0, cx1 = W, cy1 = H;
static unsigned int frames, calls;

/* ---- pixels ---------------------------------------------------------- */

static void blend(int x, int y, uint32_t c, unsigned int cover)
{
	uint32_t *d;
	unsigned int a, i, out = 0xff000000u;

	if (x < 0 || y < 0 || x >= W || y >= H)
		return;
	if (clip_on && (x < cx0 || y < cy0 || x >= cx1 || y >= cy1))
		return;
	a = ((c >> 24) * cover) / 255;
	if (a == 0)
		return;
	d = &back[y * W + x];
	if (a == 255) {
		*d = c | 0xff000000u;
		return;
	}
	for (i = 0; i < 24; i += 8) {
		unsigned int s = (c >> i) & 0xff, t = (*d >> i) & 0xff;
		out |= ((s * a + t * (255 - a)) / 255) << i;
	}
	*d = out;
}

/* Pixel (i,j) is covered when its centre (i+.5, j+.5) is inside. */
static int first_px(float v) { return (int)ceilf(v - 0.5f); }

/* ---- vita2d ---------------------------------------------------------- */

static unsigned char pool[8 << 20];
static size_t pool_used;

int vita2d_init(void) { return 0; }
int vita2d_init_advanced(unsigned int size) { (void)size; return 0; }
int vita2d_fini(void) { return 0; }
void vita2d_wait_rendering_done(void) { }
void vita2d_set_vblank_wait(int e) { (void)e; }
void vita2d_set_clear_color(unsigned int c) { clear_color = c; }
void vita2d_start_drawing(void) { pool_used = 0; }
void vita2d_end_drawing(void) { }
void vita2d_clear_screen(void)
{
	int i;
	for (i = 0; i < W * H; i++)
		back[i] = clear_color;
}
void vita2d_swap_buffers(void)
{
	memcpy(shown, back, sizeof(shown));
	frames++;
}
void vita2d_enable_clipping(void) { clip_on = 1; }
void vita2d_disable_clipping(void) { clip_on = 0; }
void vita2d_set_clip_rectangle(int x0, int y0, int x1, int y1)
{
	cx0 = x0; cy0 = y0; cx1 = x1; cy1 = y1;
}
void *vita2d_pool_memalign(unsigned int size, unsigned int align)
{
	size_t at = (pool_used + align - 1) / align * align;
	if (at + size > sizeof(pool)) {
		fprintf(stderr, "vitasim: frame pool exhausted\n");
		exit(3);
	}
	pool_used = at + size;
	return pool + at;
}
void vita2d_pool_reset(void) { pool_used = 0; }

void vita2d_draw_rectangle(float x, float y, float w, float h, unsigned int c)
{
	int i, j;
	calls++;
	for (j = first_px(y); j < first_px(y + h); j++)
		for (i = first_px(x); i < first_px(x + w); i++)
			blend(i, j, c, 255);
}

static float edge(float ax, float ay, float bx, float by, float px, float py)
{
	return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

static void fill_triangle(const vita2d_color_vertex *a,
			  const vita2d_color_vertex *b,
			  const vita2d_color_vertex *c)
{
	float area = edge(a->x, a->y, b->x, b->y, c->x, c->y);
	int minx = first_px(fminf(a->x, fminf(b->x, c->x)));
	int maxx = first_px(fmaxf(a->x, fmaxf(b->x, c->x)));
	int miny = first_px(fminf(a->y, fminf(b->y, c->y)));
	int maxy = first_px(fmaxf(a->y, fmaxf(b->y, c->y)));
	int i, j;

	if (area == 0)
		return;
	for (j = miny; j < maxy; j++) {
		for (i = minx; i < maxx; i++) {
			float px = i + 0.5f, py = j + 0.5f;
			float w0 = edge(b->x, b->y, c->x, c->y, px, py);
			float w1 = edge(c->x, c->y, a->x, a->y, px, py);
			float w2 = edge(a->x, a->y, b->x, b->y, px, py);
			if (area < 0) { w0 = -w0; w1 = -w1; w2 = -w2; }
			if (w0 >= 0 && w1 >= 0 && w2 >= 0)
				blend(i, j, a->color, 255);
		}
	}
}

void vita2d_draw_array(SceGxmPrimitiveType mode, const vita2d_color_vertex *v,
		       size_t count)
{
	size_t i;
	calls++;
	if (mode == SCE_GXM_PRIMITIVE_TRIANGLE_FAN) {
		for (i = 1; i + 1 < count; i++)
			fill_triangle(&v[0], &v[i], &v[i + 1]);
	} else if (mode == SCE_GXM_PRIMITIVE_TRIANGLES) {
		for (i = 0; i + 2 < count; i += 3)
			fill_triangle(&v[i], &v[i + 1], &v[i + 2]);
	}
}

void vita2d_draw_line(float x0, float y0, float x1, float y1, unsigned int c)
{
	float dx = x1 - x0, dy = y1 - y0;
	int n = (int)fmaxf(fabsf(dx), fabsf(dy)), k;
	calls++;
	for (k = 0; k <= n; k++) {
		float t = n ? (float)k / n : 0;
		blend((int)floorf(x0 + dx * t), (int)floorf(y0 + dy * t), c, 255);
	}
}

void vita2d_draw_fill_circle(float x, float y, float r, unsigned int c)
{
	int i, j;
	calls++;
	for (j = first_px(y - r); j < first_px(y + r); j++)
		for (i = first_px(x - r); i < first_px(x + r); i++) {
			float dx = i + 0.5f - x, dy = j + 0.5f - y;
			if (dx * dx + dy * dy <= r * r)
				blend(i, j, c, 255);
		}
}

vita2d_texture *vita2d_create_empty_texture(unsigned int w, unsigned int h)
{
	vita2d_texture *t = calloc(1, sizeof(*t));
	if (t == NULL)
		return NULL;
	t->w = w;
	t->h = h;
	t->stride = ((w + 7) & ~7u) * 4;	/* vita2d pads rows to 8 px */
	t->data = calloc(t->stride, h);
	if (t->data == NULL) {
		free(t);
		return NULL;
	}
	return t;
}
void vita2d_free_texture(vita2d_texture *t)
{
	if (t != NULL) {
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
	int i, j;
	calls++;
	for (j = first_px(y); j < first_px(y + t->h * sy); j++)
		for (i = first_px(x); i < first_px(x + t->w * sx); i++) {
			unsigned int u = (unsigned int)((i + 0.5f - x) / sx);
			unsigned int v = (unsigned int)((j + 0.5f - y) / sy);
			const unsigned char *p;
			if (u >= t->w || v >= t->h)
				continue;
			p = t->data + v * t->stride + u * 4;
			blend(i, j, (uint32_t)p[0] | (uint32_t)p[1] << 8 |
			      (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24, 255);
		}
}

/* ---- "PGF": FreeType ------------------------------------------------- */

static FT_Library ft;
static FT_Face face;
static int face_px;

static int set_px(float scale)
{
	int px = (int)(scale * PGF_EM_PX + 0.5f);
	if (px < 1)
		px = 1;
	if (px != face_px) {
		FT_Set_Pixel_Sizes(face, 0, (FT_UInt)px);
		face_px = px;
	}
	return px;
}

/* Minimal UTF-8 decode; invalid bytes decode as themselves. */
static uint32_t next_cp(const char **s)
{
	const unsigned char *p = (const unsigned char *)*s;
	uint32_t c = p[0];
	int n = 0, k;

	if (c >= 0xf0) { c &= 0x07; n = 3; }
	else if (c >= 0xe0) { c &= 0x0f; n = 2; }
	else if (c >= 0xc0) { c &= 0x1f; n = 1; }
	for (k = 1; k <= n && (p[k] & 0xc0) == 0x80; k++)
		c = (c << 6) | (p[k] & 0x3f);
	*s += k;
	return c;
}

vita2d_pgf *vita2d_load_default_pgf(void)
{
	const char *path = getenv("VITA_SIM_FONT");
	if (path == NULL)
		path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";
	if (FT_Init_FreeType(&ft) != 0 || FT_New_Face(ft, path, 0, &face) != 0) {
		fprintf(stderr, "vitasim: cannot load font %s\n", path);
		return NULL;
	}
	return (vita2d_pgf *)face;
}
void vita2d_free_pgf(vita2d_pgf *f) { (void)f; }

int vita2d_pgf_draw_text(vita2d_pgf *f, int x, int y, unsigned int color,
			 float scale, const char *text)
{
	int pen = x;
	calls++;
	set_px(scale);
	while (*text) {
		uint32_t cp = next_cp(&text);
		FT_Bitmap *bm;
		unsigned int r, c;
		if (FT_Load_Char(face, cp, FT_LOAD_RENDER) != 0)
			continue;
		bm = &face->glyph->bitmap;
		for (r = 0; r < bm->rows; r++)
			for (c = 0; c < bm->width; c++)
				blend(pen + face->glyph->bitmap_left + (int)c,
				      y - face->glyph->bitmap_top + (int)r, color,
				      bm->buffer[r * bm->pitch + c]);
		pen += (int)(face->glyph->advance.x >> 6);
	}
	return pen - x;
}

int vita2d_pgf_text_width(vita2d_pgf *f, float scale, const char *text)
{
	int w = 0;
	set_px(scale);
	while (*text) {
		uint32_t cp = next_cp(&text);
		if (FT_Load_Char(face, cp, FT_LOAD_DEFAULT) == 0)
			w += (int)(face->glyph->advance.x >> 6);
	}
	return w;
}

int vita2d_pgf_text_height(vita2d_pgf *f, float scale, const char *text)
{
	return set_px(scale);
}

/* ---- PNG out --------------------------------------------------------- */

static void put_chunk(FILE *fp, const char *type, const unsigned char *d,
		      uint32_t len)
{
	unsigned char hdr[8];
	uint32_t crc;

	hdr[0] = len >> 24; hdr[1] = len >> 16; hdr[2] = len >> 8; hdr[3] = len;
	memcpy(hdr + 4, type, 4);
	fwrite(hdr, 1, 8, fp);
	if (len)
		fwrite(d, 1, len, fp);
	crc = crc32(crc32(0, (const Bytef *)type, 4), d, len);
	hdr[0] = crc >> 24; hdr[1] = crc >> 16; hdr[2] = crc >> 8; hdr[3] = crc;
	fwrite(hdr, 1, 4, fp);
}

static void write_png(const char *path, const uint32_t *px)
{
	static unsigned char raw[H * (1 + W * 3)];
	unsigned char ihdr[13] = { 0, 0, W >> 8, W & 0xff, 0, 0, H >> 8, H & 0xff,
				   8, 2, 0, 0, 0 };
	uLongf zlen = compressBound(sizeof(raw));
	unsigned char *z = malloc(zlen);
	FILE *fp = fopen(path, "wb");
	int x, y;

	if (fp == NULL || z == NULL) {
		fprintf(stderr, "vitasim: cannot write %s\n", path);
		exit(3);
	}
	for (y = 0; y < H; y++) {
		unsigned char *row = raw + y * (1 + W * 3);
		row[0] = 0;
		for (x = 0; x < W; x++) {
			uint32_t c = px[y * W + x];
			row[1 + x * 3] = c & 0xff;
			row[2 + x * 3] = (c >> 8) & 0xff;
			row[3 + x * 3] = (c >> 16) & 0xff;
		}
	}
	compress2(z, &zlen, raw, sizeof(raw), 6);
	fwrite("\x89PNG\r\n\x1a\n", 1, 8, fp);
	put_chunk(fp, "IHDR", ihdr, 13);
	put_chunk(fp, "IDAT", z, (uint32_t)zlen);
	put_chunk(fp, "IEND", NULL, 0);
	fclose(fp);
	free(z);
}

/* ---- scripted input -------------------------------------------------- */

/* Polls with no new frame before a page counts as settled (~1 s: the
 * frontend sleeps 16 ms per idle poll). */
#define SETTLE_POLLS 60
#define MAX_POLLS 20000

int sceCtrlSetSamplingMode(SceCtrlPadInputMode mode) { (void)mode; return 0; }

int sceCtrlPeekBufferPositive(int port, SceCtrlData *pad, int count)
{
	static unsigned int polls, idle, last_frames, page, frames_at_press;
	const char *out = getenv("VITA_SIM_OUT");
	const char *pages_s = getenv("VITA_SIM_PAGES");
	unsigned int pages = pages_s ? (unsigned int)atoi(pages_s) : 1;

	memset(pad, 0, sizeof(*pad));
	pad->lx = pad->ly = pad->rx = pad->ry = 128;
	if (++polls > MAX_POLLS) {
		fprintf(stderr, "vitasim: timed out on page %u\n", page);
		exit(4);
	}
	if (frames != last_frames) {
		last_frames = frames;
		idle = 0;
		return 1;
	}
	if (++idle < SETTLE_POLLS)
		return 1;

	/* Settled: record this page, then move on. */
	if (frames == 0) {
		fprintf(stderr, "vitasim: page %u never drew a frame\n", page);
		exit(5);
	}
	if (page > 0 && frames == frames_at_press) {
		fprintf(stderr, "vitasim: page %u drew no new frame\n", page);
		sim_failures++;
	}
	if (out != NULL) {
		char path[1024];
		snprintf(path, sizeof(path), "%s/page-%02u.png", out, page);
		write_png(path, shown);
	}
	printf("vitasim: page %u settled after %u frames, %u draw calls total\n",
	       page, frames, calls);
	idle = 0;
	page++;
	frames_at_press = frames;
	pad->buttons = (page >= pages) ? SCE_CTRL_START : SCE_CTRL_RTRIGGER;
	return 1;
}

/* ---- kernel ---------------------------------------------------------- */

int sceKernelDelayThread(SceUInt delay)
{
	usleep(delay);
	return 0;
}

int sceKernelExitProcess(int res)
{
	exit(sim_failures ? 6 : res);
}
