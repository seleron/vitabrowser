# MutationObserver — design note (doc 19 no-nested-re-entry constraint)

## Status

`qjs_queue_attribute_mutation` exists (macsurf_qjs.c:6048, 7229): attribute
mutations are queued. This note covers the delivery design, not the queue.

## Constraint (from doc 19)

Doc 19 §"no nested synchronous re-entry": a MutationObserver callback must
never re-enter a running script synchronously. The observer callback runs
as a separate task on the JS task queue (like postMessage), never inline
inside the mutating call.

## Design

1. **Queue, don't deliver.** `qjs_queue_attribute_mutation` appends a
   MutationRecord (type, target, attributeName, oldValue) to the observer's
   pending list. No JS runs at queue time.

2. **Microtask checkpoint.** After the current JS task completes (the same
   `macos9_reconvert_js_task_complete` point that schedules the reconvert
   debounce), if any observer has pending records, enqueue a delivery task.

3. **Delivery task.** The delivery task invokes each observer's callback
   with its pending records, then clears the list. Records queued *by* the
   callback go to a fresh list and are delivered in a *later* task — never
   recursively in the same delivery. This bounds re-entrancy: a callback
   that mutates the DOM schedules another delivery task, it does not nest.

4. **Interaction with reconvert.** The delivery task is a JS task; when it
   completes, `js_task_complete` schedules the reconvert debounce normally.
   Observer-driven mutations thus reconvert exactly like script-driven ones.
   No special casing.

## Non-goals

- Synchronous delivery (violates the constraint; also unobservable per spec
  — the spec mandates async delivery).
- Compound "attributeFilter" optimization: filter at queue time (cheap
  string compare), not at delivery.
- Observing the frame document (doc 19 item 7): observers on the child
  document deliver on the child's task queue; cross-realm delivery follows
  the postMessage path, not a nested call.

## Status (2026-10-25): implemented as patch 317

Steps 1–4 landed: a C record queue that runs no JS to queue (libdom
node references, keyed by the destination context), drained between
page tasks next to the postMessage drain, with records built inside
the destination realm and a detached queue so a callback's records
arrive in a later delivery. The frame-document case in the non-goals
now works as described there: parent-made writes through patch 307's
handles queue for the child realm and are delivered on the child's
own delivery task. Doc 10 records the gate (MODELIV 6/6) and the
remaining gaps (innerHTML/textContent records, takeRecords).
