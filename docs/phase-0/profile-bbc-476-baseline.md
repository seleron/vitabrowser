# Load profile: bbc (https://www.bbc.com/news)

| | L1 | L2 |
|---|---|---|
| first Done (s) | 3.7 | 3.3 |
| heap at Done (KiB) | 128445 | 130156 |
| heap peak (KiB) | 135163 | 135224 |
| llcache objects created | 129 | 129 |
| llcache objects destroyed | 22 | 22 |
| llcache refetched (created again) | 6 | 6 |
| llcache size peak (bytes) | 6172863 | 6189410 |
| layout (ms) | 56 | 55 |
| box + cascade (ms) | 1405.2 | 1075.7 |
| JS compile (ms) | 384.7 | 324.4 |
| JS run (ms) | 65.1 | 55.2 |
| JS gc (ms) | 2.8 | 2.2 |
| full rebuilds | 1 | 1 |
| local rebuilds (ms) | 44.9 | 45.8 |

## CPU samples by phase (percent of the load's samples)

| phase | L1 | L2 |
|---|---|---|
| fetch/TLS | 10.7 | 11.8 |
| HTML parse | 0.1 | 0.4 |
| CSS parse | 0.8 | 0.2 |
| style selection | 1.2 | 0.9 |
| box build | 0.3 | 0.1 |
| layout | 0.9 | 1.0 |
| paint | 1.1 | 1.5 |
| font | 0.3 | 0.2 |
| image decode | 0.1 | 0.0 |
| JS | 61.2 | 61.6 |
| DOM | 1.3 | 1.4 |
| malloc | 20.7 | 19.1 |
| other | 1.3 | 1.8 |
| (samples) | 1055 | 953 |

Top leaf functions (L1):

- [libc.so.6]: 208
- JS_CallInternal: 186
- mbedtls_ct_base64_dec_value: 61
- js_dup: 30
- find_own_property: 28
- lre_exec_backtrack: 22
- JS_FreeValueRT: 18
- next_token: 17
- __JS_FindAtom: 15
- mbedtls_base64_decode: 12
- js_call_c_function: 12
- strv: 10
- mbedtls_x509_crt_parse_der_internal: 9
- __JS_AtomToValue: 9
- find_hashed_shape_prop: 8

Refetched URLs (L1): resource:default.css, resource:user.css, file:///app0%3A/res/default.css, file:///app0%3A/res/user.css, resource:internal.css, file:///app0%3A/res/internal.css
