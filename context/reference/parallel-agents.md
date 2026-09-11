# Fanning out to parallel agents

> Loaded on demand — not part of the SessionStart payload. Read it before spawning agents that
> work on the tree at the same time (BUILD phase of `groundwork.md`).

Each agent gets an exclusive file list, and is told
which neighbouring files a sibling is holding. Also tell it:

- your brief may already be stale — verify premises against the tree, not against what
  the brief asserts (a brief once said an endpoint wrote nothing to the database while
  another agent was adding a write to it)
- fallout reaching a file it does not own means **stop and report the list**, never guess
- `git checkout` / `stash` / `reset` are forbidden: they discard siblings' work
- run verification in the **foreground**; never start a background job and end the turn
  waiting on it
- paste failing-first evidence: break the line the test covers, watch it go red, restore
  by retyping, watch it go green

Verify each agent's claims yourself, ideally by breaking something *different* from what
it reported. Reports are evidence, not proof.
