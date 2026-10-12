/* sprof -- a sampling profiler for the simulator (patch 253's tool).
 *
 * LD_PRELOAD it: SIGPROF on every CPU-time tick asked for (SPROF_US,
 * default 500 us -- WSL's kernel delivers about every 4 ms), backtrace()
 * of the interrupted code, a CLOCK_MONOTONIC stamp and the thread id; it
 * also logs every usleep (start, end, asked) so idle time shows. At exit
 * it writes SPROF_OUT.<pid> (one sample per line: stamp tid frames...),
 * .maps and .sleeps. Per pid because LD_PRELOAD also loads into a
 * wrapper such as timeout(1), which exits last.
 *
 *   gcc -O2 -shared -fPIC -o sprof.so tools/vita-sim/sprof.c -ldl
 *   SPROF_OUT=/tmp/p LD_PRELOAD=./sprof.so nsvita-sim URL
 *   tools/vita-sim/sprof-sym.py /tmp/p.<pid> <path>/nsvita-sim
 *
 * Samples are wall-clock positioned but CPU-time driven: a gap in which
 * the program sleeps or waits has no samples -- read .sleeps too.
 */
#define _GNU_SOURCE
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <sys/syscall.h>

#define MAXS 400000
#define DEPTH 40
static void *frames[MAXS][DEPTH];
static unsigned char depth[MAXS];
static long long stamp[MAXS];
static int tids[MAXS];
static volatile int n;
static pid_t main_tid;
static long long init_us;
#define MAXSL 200000
static long long sl_start[MAXSL], sl_end[MAXSL];
static unsigned sl_req[MAXSL];
static int nsl;
static long long mono_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000LL + t.tv_nsec / 1000; }
#include <dlfcn.h>
int usleep(useconds_t us)
{
	static int (*real)(useconds_t);
	long long a = mono_us();
	int r;
	if (!real) real = dlsym(RTLD_NEXT, "usleep");
	r = real(us);
	if (nsl < MAXSL) { sl_start[nsl] = a; sl_end[nsl] = mono_us(); sl_req[nsl] = us; nsl++; }
	return r;
}

static void handler(int sig, siginfo_t *si, void *uc)
{
	struct timespec t;
	int i;
	(void)sig; (void)si; (void)uc;
	if (n >= MAXS) return;
	i = __sync_fetch_and_add(&n, 1);
	if (i >= MAXS) return;
	tids[i] = (int)syscall(SYS_gettid);
	clock_gettime(CLOCK_MONOTONIC, &t);
	stamp[i] = t.tv_sec * 1000000LL + t.tv_nsec / 1000;
	depth[i] = (unsigned char)backtrace(frames[i], DEPTH);
}

static void dump(void)
{
	const char *out = getenv("SPROF_OUT");
	char path[512], buf[4096];
	FILE *f, *m;
	int i, j;
	struct itimerval z;
	size_t k;
	memset(&z, 0, sizeof(z));
	setitimer(ITIMER_PROF, &z, NULL);
	char outp[512];
	if (!out) out = "sprof.out";
	if (n == 0) return;
	snprintf(outp, sizeof(outp), "%s.%d", out, (int)getpid());
	out = outp;
	f = fopen(out, "w");
	if (!f) return;
	for (i = 0; i < n; i++) {
		fprintf(f, "%lld %d", stamp[i], tids[i]);
		for (j = 0; j < depth[i]; j++) fprintf(f, " %p", frames[i][j]);
		fputc('\n', f);
	}
	fclose(f);
	snprintf(path, sizeof(path), "%s.sleeps", out);
	f = fopen(path, "w");
	if (f) {
		fprintf(f, "init %lld\n", init_us);
		for (i = 0; i < nsl; i++) fprintf(f, "%lld %lld %u\n", sl_start[i], sl_end[i], sl_req[i]);
		fclose(f);
	}
	snprintf(path, sizeof(path), "%s.maps", out);
	m = fopen("/proc/self/maps", "r");
	f = fopen(path, "w");
	while (m && f && (k = fread(buf, 1, sizeof(buf), m)) > 0) fwrite(buf, 1, k, f);
	if (m) fclose(m);
	if (f) fclose(f);
}

__attribute__((constructor)) static void init(void)
{
	struct sigaction sa;
	struct itimerval it;
	void *tmp[2];
	const char *us = getenv("SPROF_US");
	main_tid = (pid_t)syscall(SYS_gettid);
	init_us = mono_us();
	backtrace(tmp, 2);	/* load libgcc before the first signal */
	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = handler;
	sa.sa_flags = SA_SIGINFO | SA_RESTART;
	sigaction(SIGPROF, &sa, NULL);
	it.it_interval.tv_sec = 0;
	it.it_interval.tv_usec = us ? atoi(us) : 500;
	it.it_value = it.it_interval;
	setitimer(ITIMER_PROF, &it, NULL);
	atexit(dump);
}
