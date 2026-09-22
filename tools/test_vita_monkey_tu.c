/* Monkey half of tools/test_vita_plotter.c.
 *
 * Includes the REAL patched frontends/monkey/plot.c (patches 25-27) so its
 * static monkey_plot_rectangle() can be called, with a moutf() stub that
 * captures the PLOT lines. It lives in its own translation unit because
 * monkey's plot.c and the Vita plot.c both define a static `plotters` table.
 */
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

#include "netsurf/plotters.h"
#include "monkey/output.h"

#include "monkey/plot.c"

void test_monkey_rectangle(const plot_style_t *style, const struct rect *r,
			   char *out, size_t cap);

static char *cap_buf;
static size_t cap_len, cap_size;

int moutf(enum monkey_output_type mout_type, const char *fmt, ...)
{
	char tmp[512];
	va_list ap;
	int n;

	if (mout_type != MOUT_PLOT || cap_buf == NULL)
		return 0;
	va_start(ap, fmt);
	n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
	va_end(ap);
	if (n < 0)
		return 0;
	/* One op per line, like the real stream. */
	cap_len += (size_t)snprintf(cap_buf + cap_len, cap_size - cap_len,
				    "%s\n", tmp);
	if (cap_len >= cap_size)
		cap_len = cap_size - 1;
	return 0;
}

void test_monkey_rectangle(const plot_style_t *style, const struct rect *r,
			   char *out, size_t cap)
{
	static struct redraw_context ctx;

	cap_buf = out;
	cap_size = cap;
	cap_len = 0;
	out[0] = '\0';
	monkey_plot_rectangle(&ctx, style, r);
	cap_buf = NULL;
}
