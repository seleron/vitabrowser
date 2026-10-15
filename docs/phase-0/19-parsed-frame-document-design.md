# Item 7 (design, 2026-10-14): a parsed frame's real document for the parent's realm

Design only — no implementation in this document's commit. This is the
design pass Doc 10's item 7 entry (recorded with patch 297) called for,
in the open, as patch 186 had (doc 17). It completes patch 288's
"not done": since patch 143 the parent realm sees a shim window for a
parsed iframe (postMessage works, patch 244), and since patch 294 a
shim document for a same-origin frame or null for a cross-origin one.
What is missing is the REAL document: a parent script that reads
`frame.contentWindow.document` today gets the shim, whose queries do
not reach the frame's parsed tree.

## Constraints (from the record, not negotiable in the design)

1. **Only C crosses between runtimes.** A JSValue is runtime-specific;
   handing one across is the crash class the cross-realm postMessage
   work (patch 244) was built to avoid. Every value that moves —
   reads, results, node references — is marshalled through C, in the
   shape of the existing message queue.
2. **One runtime per frame stays.** A single shared runtime for all
   frames would undo the isolation the frame work since patch 143 is
   built on (doc 12). The child's document is answered IN the child's
   realm; the parent holds handles, never objects.
3. **Cross-origin stays null** (patch 294). The same-origin test is
   the one patch 294 already applies; nothing in this design weakens
   it, and the gate page proves both sides again.
4. **Lifetime is validated, never assumed.** The handle carries the
   owner/generation pair the realm-hop natives already use
   (`qjs_thread_owner` tokens; `js_realm_valid_for_content(thread,
   content, generation)`), the shape `__vitaSubmitForm` (patch 263)
   and `__vitaFollowLink` (patch 292) validate before they act. A
   handle whose frame content has navigated or been destroyed fails
   closed: reads answer undefined/empty, calls are dropped, nothing
   dereferences the dead side.

## Shape

The parent's `contentWindow.document` for a same-origin parsed frame
becomes a **marshalled document handle**: a parent-realm object whose
properties and methods are natives. Each native packs a request
(op, handle id, arguments as C strings/scalars), the bridge delivers
it to the child realm's execution point (the cooperative scheduler
point the postMessage queue already uses — never a nested synchronous
re-entry into a running child script), the child answers against its
own libdom tree, and the result is marshalled back.

Handles, not copies: a node answer is a **node handle** — a
parent-realm wrapper carrying (child content token, generation, node
identity). The child side keeps the node alive for the handle's
lifetime via the same referenced-node discipline the reconvert
pending table uses (`macsurf_reconvert_node_ref`). If the generation
check fails at use time, the wrapper is inert (see constraint 4).

The rejected alternatives, for the record (from Doc 10's note,
unchanged): a read-only snapshot — serializing the child's tree into
the parent's heap — is wrong for live access (the parent's writes
would land in the copy); a shared runtime is constraint 2.

## Staged surface

Each stage is its own patch, gated, in this order. No stage widens
the surface before the previous stage's gate page passes.

- **Stage 1 — scalar document handle.** `contentWindow.document`
  returns the handle. Scalar state read through the bridge:
  `URL`, `title`, `readyState`, `documentElement` / `body` /
  `head` as node handles (identity only at this stage: `tagName`,
  `nodeType`). Proves marshalling, generation validation, and the
  null cross-origin side end to end with the smallest surface.
- **Stage 2 — queries.** `getElementById`, `querySelector`,
  `querySelectorAll`, `getElementsByTagName` on the document handle,
  answered in the child's realm, returning node handles (lists as
  parent-realm arrays of handles). Selector evaluation stays in the
  child: the parent never sees the child's selector engine state.
- **Stage 3 — node handle reads/writes.** On node handles:
  `textContent`, `innerHTML` (get/set), `getAttribute` /
  `setAttribute`, `childNodes` / `firstChild` / `parentNode`
  traversal as handles, `appendChild` / `removeChild` taking
  handles of the same child document. Writes land in the child's
  DOM and flow through the child's own mutation/reconvert machinery
  — the parent does not get a private invalidation path.

Out of scope at every stage: events crossing the boundary (a listener
registered from the parent on a child node), `contentWindow` writes,
adopting a node INTO the parent's document (a handle is not a node of
the parent's tree; `parentDocument.appendChild(childHandle)` stays a
type error), and anything cross-origin.

## Failure and lifetime semantics (specified, not discovered later)

- Frame navigates (same-origin → same-origin): the generation bumps;
  outstanding node handles go inert (constraint 4); the document
  handle rebinds to the new document on next access, as a browser's
  does.
- Frame removed from the parent's tree: content token dies with it;
  handles inert; the document handle answers as a null document
  (properties undefined, queries empty) rather than throwing across
  the boundary.
- Child mid-script when a request arrives: the request queues to the
  child's next scheduler point (constraint 1). The parent's native
  does NOT spin-wait: reads that cannot be answered synchronously
  from already-marshalled state answer the last marshalled value for
  scalars (stage 1 caches URL/title/readyState on child state
  changes), and stage 2/3 calls queue and answer on delivery —
  which, for a synchronous JS API, means the design needs the same
  settle/flush discipline the geometry reads use (one synchronous
  flush per execution, budget-guarded, declining to the stale
  answer past budget). This is the hardest part of the design and
  the reason stage 1 is scalars-only: its flush is provable before
  queries depend on it.

## Gate page (spec)

`testpages/pages/JS-frame-document.html`, checks prefixed XDOC2,
added to the gate when stage 1 lands:

1. Same-origin parsed iframe: parent reads
   `contentWindow.document.URL` / `.title` / `.readyState` — equal
   to the child's own values (the child writes its title from its
   own script; the parent must read the NEW value, proving the
   read crosses).
2. `documentElement.tagName === 'HTML'`, `body` non-null and
   identical (`===`) across two reads (handle identity is stable).
3. Stage 2: `getElementById` finds an element the child created
   after load (proving live access, not a snapshot);
   `querySelectorAll('p')` length matches the child's count.
4. Stage 3: parent sets `textContent` on a child node handle; the
   child's own script observes the new text (proving the write
   crosses and lands in the child's DOM); parent sets innerHTML on
   a child container and reads back the child's child count.
5. Lifetime: parent navigates the frame (same-origin, second page);
   the pre-navigation node handle is inert (reads undefined, no
   crash); the document handle answers the new page's title.
6. Cross-origin frame (the gate server's second origin):
   `contentWindow.document` is null (patch 294's XDOC checks hold).

Existing checks that must hold at every stage: XFRAME (shim window /
postMessage), XDOC (294's cross-origin null + same-origin shim
behaviour the stages replace in place — its same-origin expectations
are updated by the stage patch, its cross-origin ones are not).

## Cost expectation

A cross-realm read is a scheduler round trip, not a property load:
this surface is for reach (frameworks that probe frame documents,
embed widgets), not for speed, and the design says so plainly so no
one builds a hot loop on it. The parent's own-document paths are
untouched.
