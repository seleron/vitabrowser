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
 * Whether the DOM fires the window load event (readyState 'complete')
 * through the JS bridge. Off while the bridge was not wired up; on since
 * patch 130: the QuickJS bridge runs every page and script geometry is
 * real (patch 111), and without it no page ever saw window load or
 * readyState 'complete' -- $(window).on('load'), onload initialisers and
 * readyState polling all waited forever.
 */
#ifndef MACSURF_JS_FIRE_LOAD
#define MACSURF_JS_FIRE_LOAD 1
#endif

#endif /* VITABROWSER_MACSURF_CONFIG_H */
