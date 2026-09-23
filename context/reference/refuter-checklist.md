# Refuter — standing checklist

> Loaded on demand — not part of the SessionStart payload. Run every item below against the
> diff on every refuter/review pass, in addition to the task-specific brief. Each pattern
> recurred across unrelated features before it had a name; checking for it by habit is
> cheaper than rediscovering it per review.

| # | Pattern | How to probe it |
|---|---|---|
| R1 | **Error shown as absence.** A failed or pending lookup collapses to "empty / disabled / out of scope" instead of a distinct state the UI or caller can act on. | Force the dependency to fail or time out (kill the mock, block the endpoint) and check whether the result is distinguishable from "genuinely empty" and from "no access". If both render the same, it's this pattern. |
| R2 | **Cache keyed without session or context.** A cache survives a context change (logout, tenant switch, scope change) that should have invalidated it. | Populate the cache, switch session/tenant/context, read again. If the stale value comes back, the key is missing a dimension. |
| R3 | **Context threaded ad hoc.** The same piece of state (mode, id, lock, label) is re-derived independently in more than one place — a query param here, a route data field there, a component field somewhere else — instead of owned by one service and passed down. | Grep for the concept's name across the diff and the files it touches; more than one place computing or storing it independently is the smell. Change it in one place and see if the others go stale. |
| R4 | **Platform facts hand-encoded, then checked against a stale sample.** A deny list, scope table, or enum copied from one observation of the running system, never re-verified. | Diff the hard-coded fact against a fresh, direct probe of the real system (a live query, not a fixture). A fact that hasn't been re-checked since it was written is a guess with a stale timestamp. |
| R5 | **A near-duplicate traversal.** A new tree/graph walk that reimplements the for/try/switch shape of an existing one instead of extending it. | Before accepting a new traversal function, search the codebase (grep or a structural index) for an existing one over the same data shape. Two walks that would both need the same bug fixed independently are the same walk written twice. |
| R6 | **Prose drifts from code.** A comment, docstring, module guide or generated-doc example asserts something the code no longer does. | Re-read every claim the diff's comments/docs make against the code they describe, including examples — an example that the code itself would reject is a caught lie, not a style nit. |
| R7 | **Vacuous spec.** A test that passes whether or not the fix is present — it asserts a shape, not the behavior; or it pins the wrong failure. | **Revert the fix and re-run the spec.** If it does not go red, it proves nothing. This is the single highest-value check in this list — run it even when time is short. |

Also check on every pass, regardless of task:

- **Duplicated helpers instead of reused ones** — search for an existing implementation of the
  same concept before accepting a new one; a helper re-implemented under a new name is a defect,
  not a style choice.
- **House rules that are prose-only get broken** — a comment style ban, a forbidden pattern, a
  "never do X" rule that has no hook behind it is the rule most likely to be violated under
  time pressure. Check the diff against every such rule by hand; do not assume the rule held.
- **Removals from a shared source-of-truth file** (translation keys, generated manifests,
  config tables) — confirm each removal was intended, not a side effect of a script that
  regenerates the whole file from a smaller input.
