/* m3run mod.wasm calls.json i : same output as v8run.js, through our wasm3 (host libm3.a) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <zlib.h>
#include "wasm3.h"
static const void *stub(IM3Runtime rt, IM3ImportContext ctx, uint64_t *sp, void *mem) { (void)rt;(void)ctx;(void)mem; *sp = 0; return m3Err_none; }
static char *slurp(const char *p, long *n) { FILE *f = fopen(p, "rb"); fseek(f, 0, 2); *n = ftell(f); rewind(f); char *b = malloc(*n + 1); fread(b, 1, *n, f); b[*n] = 0; fclose(f); return b; }
static const char *trapk(const char *r) {
	if (strstr(r, "out of bounds")) return "oob"; if (strstr(r, "unreachable")) return "unreach";
	if (strstr(r, "divide by zero")) return "div0"; if (strstr(r, "overflow") && strstr(r, "integer")) return "ovf";
	if (strstr(r, "conversion")) return "conv"; if (strstr(r, "stack")) return "stack"; return r; }
int main(int argc, char **argv) {
	long n, cn; unsigned char *buf = (unsigned char *)slurp(argv[1], &n);
	/* the call list is pre-flattened by m3prep.py into lines: name|params|results then arg rows */
	FILE *cf = fopen(argv[2], "r"); int want = atoi(argv[3]); char line[8192]; int idx = -1;
	char name[64] = ""; char ps[16] = "", rs[16] = ""; char rows[3][4096]; int nrows = 0;
	while (fgets(line, sizeof line, cf)) {
		line[strcspn(line, "\n")] = 0;
		if (line[0] == '#') { idx++; if (idx == want) sscanf(line + 1, "%63[^|]|%15[^|]|%15s", name, ps, rs); if (rs[0]=='-') rs[0]=0; if (ps[0]=='-') ps[0]=0; continue; }
		if (idx == want && nrows < 3) strcpy(rows[nrows++], line);
	}
	fclose(cf); (void)cn;
	IM3Environment env = m3_NewEnvironment(); IM3Runtime rt = m3_NewRuntime(env, 1 << 20, NULL); IM3Module mod; M3Result r;
	if ((r = m3_ParseModule(env, &mod, buf, n))) { printf("parse: %s\n", r); return 1; }
	if ((r = m3_LoadModule(rt, mod))) { printf("load: %s\n", r); return 1; }
	
	{ FILE *fi = fopen(getenv("IMPORTS"), "r"); char a[64], b2[64]; while (fi && fscanf(fi, "%63s %63s", a, b2) == 2) { r = m3_LinkRawFunction(mod, strdup(a), strdup(b2), NULL, stub); } if (fi) fclose(fi); }
	IM3Function fn; if ((r = m3_FindFunction(&fn, rt, name))) { printf("find %s: %s\n", name, r); return 1; }
	for (int k = 0; k < nrows; k++) {
		int np = strlen(ps); union { int32_t i; int64_t l; float f; double d; } v[16]; const void *pv[16];
		char *s = rows[k];
		for (int i = 0; i < np; i++) {
			char *e = strchr(s, ' '); if (e) *e = 0;
			switch (ps[i]) { case 'i': v[i].i = (int32_t)strtoll(s, 0, 10); break; case 'I': v[i].l = strtoll(s, 0, 10); break;
				case 'f': v[i].f = strtof(s, 0); break; default: v[i].d = strtod(s, 0); }
			pv[i] = &v[i]; s = e ? e + 1 : s;
		}
		r = m3_Call(fn, np, pv);
		uint32_t msz = 0; uint8_t *m = m3_GetMemory(rt, &msz, 0);
		unsigned long crc = crc32(0L, m, msz);
		if (r) { printf("T %s", trapk(r)); }
		else {
			int nr = strlen(rs); union { int32_t i; int64_t l; float f; double d; uint32_t u; uint64_t U; } o[8]; const void *po[8];
			for (int i = 0; i < nr; i++) po[i] = &o[i];
			m3_GetResults(fn, nr, po); printf("R ");
			if (!nr) printf("-");
			for (int i = 0; i < nr; i++) {
				if (i) printf(",");
				switch (rs[i]) { case 'i': printf("%d", o[i].i); break; case 'I': printf("%lld", (long long)o[i].l); break;
					case 'f': if (o[i].f != o[i].f) printf("nan"); else printf("f32:%x", o[i].u); break;
					default: if (o[i].d != o[i].d) printf("nan"); else printf("f64:%llx", (unsigned long long)o[i].U); }
			}
		}
		printf(" M %lx P %u\n", crc, msz);
	}
	return 0;
}
