/* SIGSEGV tracer: dumps RIP/RSP/fault addr, /proc/self/maps, and a
 * symbolized backtrace.  Usage: LD_PRELOAD=./segvtrace.so nsvita-sim ...
 * Output: stdout (buffered) + /tmp/segv-trace.out (unbuffered).
 * Built: gcc -shared -fPIC -O1 -o segvtrace.so segvtrace.c
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <ucontext.h>

static FILE *f_out;
static void handler(int sig, siginfo_t *si, void *uctx_void)
{
	void *bt[64];
	int n = backtrace(bt, 64);
	char **syms = backtrace_symbols(bt, n);
	ucontext_t *uctx = uctx_void;
	uintptr_t rip = 0, rsp = 0;
#ifdef REG_RIP
	rip = (uintptr_t)uctx->uc_mcontext.gregs[REG_RIP];
	rsp = (uintptr_t)uctx->uc_mcontext.gregs[REG_RSP];
#endif
	fprintf(f_out, "=== FAULT sig=%d rip=%#lx rsp=%#lx fault=%p\n",
		 sig, (unsigned long)rip, (unsigned long)rsp, si->si_addr);
	fprintf(f_out, "--- maps ---\n");
	if (freopen("/proc/self/maps", "r", stdin)) {
		int c;
		while ((c = getc(stdin)) != EOF) putc(c, f_out);
	}
	fprintf(f_out, "--- backtrace (%d frames) ---\n", n);
	for (int i = 0; i < n; i++)
		fprintf(f_out, "[%02d] %s\n", i, syms ? syms[i] : "?");
	fprintf(f_out, "--- addr2line hint ---\n");
	fprintf(f_out, "Find the PIE base: first line of maps ending in nsvita-sim.\n");
	fprintf(f_out, "Then run:  addr2line -fC -e nsvita-sim $((0x%lx - 0xBASE))\n",
		 (unsigned long)rip);
	fprintf(f_out, "=== END FAULT ===\n");
	fflush(f_out);
}

__attribute__((constructor))
static void init(void)
{
	f_out = fopen("/tmp/segv-trace.out", "a");
	if (f_out) setvbuf(f_out, NULL, _IONBF, 0);
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sigemptyset(&sa.sa_mask);
	sa.sa_sigaction = handler;
	sa.sa_flags = SA_SIGINFO;
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGABRT, &sa, NULL);
}
