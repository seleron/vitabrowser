/*
 * macsurf_config.h -- VitaBrowser compatibility shim.
 *
 * MacSurf's sources test build-time switches with #if rather than #ifdef, so
 * an undefined switch is an error under upstream's -Werror=undef rather than
 * silently zero. Define them explicitly, with the value that selects the
 * behaviour we want.
 */
#ifndef VITABROWSER_MACSURF_CONFIG_H
#define VITABROWSER_MACSURF_CONFIG_H

/*
 * Whether the DOM fires a synthetic load event through the JS bridge.
 * MacSurf gates this because their bridge needed it; ours is not wired up
 * yet (compat/macsurf_compat.c's js_fire_* are no-ops), so leave it off
 * until the Vita frontend provides a real jsthread.
 */
#ifndef MACSURF_JS_FIRE_LOAD
#define MACSURF_JS_FIRE_LOAD 0
#endif

#endif /* VITABROWSER_MACSURF_CONFIG_H */
