/*
 * macos9_deathrow.h -- VitaBrowser compatibility shim.
 *
 * MacSurf added a deferred-teardown queue to netsurf's core: instead of
 * freeing a content object at the point it becomes unreachable, the frontend
 * queues it and drains the queue at a quiescent point ("top of macos9_poll,
 * outermost only"). That exists because Mac OS 9's cooperative scheduler can
 * re-enter the core from inside a callback, so freeing in place risks pulling
 * an object out from under a live frame.
 *
 * We have no such re-entry: brief §4 commits us to a single-threaded event
 * loop with non-blocking curl_multi, and nothing calls back into the core
 * mid-teardown. compat/macsurf_compat.c therefore runs the teardown
 * immediately, which is exactly what upstream NetSurf does at these call
 * sites -- MacSurf replaced a direct free with a queued one, so running it
 * now restores upstream behaviour rather than inventing new behaviour.
 *
 * If the Vita frontend ever does re-enter the core (it should not), revisit
 * this before trusting it.
 */
#ifndef VITABROWSER_MACOS9_DEATHROW_H
#define VITABROWSER_MACOS9_DEATHROW_H

struct content;

void macos9_deathrow_add(void *ptr, void (*teardown)(void *ptr),
		struct content *pin_key);
void macos9_deathrow_drain(void);

/* Liveness registry. MacSurf tracks which content objects are still valid so
 * a stale pointer can be detected; upstream has no such concept and simply
 * trusts its own lifetimes. The shim answers "live" and "valid", which is the
 * upstream assumption. */
int macos9_content_is_live(struct content *c);
unsigned long macos9_content_token(struct content *c);
int macos9_content_token_valid(struct content *c, unsigned long token);

/*
 * Re-entrancy depth. MacSurf increments this while a walk, convert, redraw or
 * broadcast is in progress and defers destructive work while it is non-zero --
 * the same cooperative-scheduler hazard the deathrow queue addresses. Our
 * event loop never re-enters the core, so it stays zero and every guarded
 * branch takes the upstream path.
 */
extern int macos9_op_depth;

#endif /* VITABROWSER_MACOS9_DEATHROW_H */
