/* Host-side stand-in for libvita2d's <vita2d.h>, used by the renderer unit
 * test (tools/test_vita_plotter.c, a logging implementation) and the host
 * simulator (tools/vita-sim/vitasim.c, a software rasteriser).
 *
 * Declares exactly the subset of the real API (~/vitasdk/arm-vita-eabi/
 * include/vita2d.h, libvita2d 0.0.0.r188) that frontends/vita uses, with the
 * same names, signatures and struct layouts, so the frontend sources compile
 * unchanged on the host. The test provides the definitions and logs every
 * call. If the frontend starts using a function not listed here, the host
 * build fails to link -- which is the point: extend this file from the real
 * header, never invent a signature.
 */
#ifndef VITA2D_H
#define VITA2D_H

#include <stddef.h>
#include <stdint.h>

#define RGBA8(r,g,b,a) ((((a)&0xFF)<<24) | (((b)&0xFF)<<16) | (((g)&0xFF)<<8) | (((r)&0xFF)<<0))

/* psp2/gxm.h: only the value the frontend passes. */
typedef enum SceGxmPrimitiveType {
	SCE_GXM_PRIMITIVE_TRIANGLES      = 0x00000000u,
	SCE_GXM_PRIMITIVE_TRIANGLE_STRIP = 0x0C000000u,
	SCE_GXM_PRIMITIVE_TRIANGLE_FAN   = 0x10000000u
} SceGxmPrimitiveType;

/* psp2/gxm.h: the texture format and filter the text atlas uses. */
typedef enum SceGxmTextureFormat {
	SCE_GXM_TEXTURE_FORMAT_U8_R111 = 0x00007000u	/* A = texel, RGB = 1 */
} SceGxmTextureFormat;

typedef enum SceGxmTextureFilter {
	SCE_GXM_TEXTURE_FILTER_POINT  = 0x00000000u,
	SCE_GXM_TEXTURE_FILTER_LINEAR = 0x00000001u
} SceGxmTextureFilter;

typedef struct vita2d_color_vertex {
	float x;
	float y;
	float z;
	unsigned int color;
} vita2d_color_vertex;

/* Opaque on the host; the test's stub owns the fields. `alpha8` marks a
 * SCE_GXM_TEXTURE_FORMAT_U8_R111 texture (1 byte a texel), else RGBA8. */
typedef struct vita2d_texture {
	unsigned int w, h, stride;
	unsigned char *data;
	int alpha8;
} vita2d_texture;

int vita2d_init(void);
int vita2d_init_advanced(unsigned int temp_pool_size);
int vita2d_fini(void);
void vita2d_wait_rendering_done(void);
void vita2d_start_drawing(void);
void vita2d_end_drawing(void);
void vita2d_clear_screen(void);
void vita2d_swap_buffers(void);
void *vita2d_get_current_fb(void);
void vita2d_set_clear_color(unsigned int color);
void vita2d_set_vblank_wait(int enable);

void vita2d_enable_clipping(void);
void vita2d_disable_clipping(void);
void vita2d_set_clip_rectangle(int x_min, int y_min, int x_max, int y_max);

void *vita2d_pool_memalign(unsigned int size, unsigned int alignment);
void vita2d_pool_reset(void);

void vita2d_draw_line(float x0, float y0, float x1, float y1, unsigned int color);
void vita2d_draw_rectangle(float x, float y, float w, float h, unsigned int color);
void vita2d_draw_fill_circle(float x, float y, float radius, unsigned int color);
void vita2d_draw_array(SceGxmPrimitiveType mode, const vita2d_color_vertex *vertices, size_t count);

vita2d_texture *vita2d_create_empty_texture(unsigned int w, unsigned int h);
vita2d_texture *vita2d_create_empty_texture_format(unsigned int w, unsigned int h, SceGxmTextureFormat format);
void vita2d_texture_set_filters(vita2d_texture *texture, SceGxmTextureFilter min_filter, SceGxmTextureFilter mag_filter);
void vita2d_free_texture(vita2d_texture *texture);
unsigned int vita2d_texture_get_width(const vita2d_texture *texture);
unsigned int vita2d_texture_get_height(const vita2d_texture *texture);
unsigned int vita2d_texture_get_stride(const vita2d_texture *texture);
void *vita2d_texture_get_datap(const vita2d_texture *texture);
void vita2d_draw_texture_scale(const vita2d_texture *texture, float x, float y, float x_scale, float y_scale);
void vita2d_draw_texture_tint_part(const vita2d_texture *texture, float x, float y, float tex_x, float tex_y, float tex_w, float tex_h, unsigned int color);

typedef struct vita2d_texture_vertex {
	float x;
	float y;
	float z;
	float u;
	float v;
} vita2d_texture_vertex;

void vita2d_draw_array_textured(const vita2d_texture *texture, SceGxmPrimitiveType mode, const vita2d_texture_vertex *vertices, size_t count, unsigned int color);

#endif
