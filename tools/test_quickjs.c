/* Host driver for frontends/vita/jsprobe.c: see tools/test-quickjs.sh. */
#include <stdarg.h>
#include <stdio.h>

#include "vita/jsprobe.h"

static void log_line(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	putchar('\n');
}

int main(void)
{
	struct vita_jsprobe_result r;

	vita_jsprobe_run(log_line, &r);
	return r.failed != 0 || r.checks < 18;
}
