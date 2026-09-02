---
name: commit-gate-guard
description: Pre-commit review gate. Runs one small, bounded review pass over everything changed since the last recorded review — not just the staged diff — and blocks the commit on a CRITICAL/IMPORTANT finding. Use before `git commit`, after applying a fix. Projects add their own runtime/browser checks on top.
---

# Commit Gate-Guard (generic)

A pre-commit **review** gate. You verify — you do NOT commit, do NOT amend, do NOT edit
source. Return a one-line verdict with evidence.

## Why this exists

A full multi-agent review (`/review-all` or equivalent) only ever sees the code as it was
*when it ran*. The fixes written **in response to** its findings, and everything committed
after it, are reviewed by nothing.

That gap ships bugs. Measured case: a review found a real issue, the fix for it
introduced a `||` chain where a creation-only condition silently overrode an update rule,
and it reached the merge request. Typecheck, lint, the browser check and the whole spec
suite were green — because the specs were written by the same author, in the same pass, under
the same wrong assumption. A human reviewer caught it afterwards.

So: **review the delta since the last review, every time, before committing.** One small pass.
It is not a substitute for a full review; it closes the window a full review structurally
cannot see.

## Procedure

### 1. Stage first

`git add` the intended files. The gate fingerprints `git diff --cached`, so the staged set
must match exactly what will be committed. Re-staging after a PASS invalidates the marker.

### 2. Resolve the review baseline

In order:

1. `.claude/.commit-gate/last-review` — the sha this gate last reviewed. Normal case.
2. Absent → the merge-base with the default branch
   (`git merge-base HEAD "$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"`).
   First run on a branch reviews the whole branch, which is the honest default.
3. Detached/shallow/no upstream → fall back to `git diff --cached` alone and **say so** in the
   verdict, so the reader knows the scope was narrowed.

The delta is then everything between the baseline and the about-to-be-committed state:

```sh
git diff "$BASELINE" > /tmp/commit-gate-delta.diff        # commits since baseline + working tree
git diff --cached >> /tmp/commit-gate-delta.diff          # ensure staged-only changes are included
```

Do not anchor the baseline on a review tool's findings log. A run that finds nothing writes
nothing, so "no entry" and "never ran" are indistinguishable — the marker below is what makes
this reliable.

### 3. One small review pass

Skip **only** when the delta touches no code (docs, `*.md`, `.claude/`, config-only). Say
`review: N/A (no code in delta)` and go to the marker.

Spawn **ONE** `general-purpose` agent with an explicit `model: opus` — one pass, no verifier
fan-out, no multi-axis spawn. That is what keeps this cheap enough to run on every commit.

Give it:
- If the **review-all** companion plugin is installed, its bugs persona plus shared rules:
  `~/.claude/plugins/cache/*/review-all/*/skills/review-all/agents/02-bugs-security.md` and
  `.../agents/_shared.md`. Resolve the glob before spawning; do not assume the path exists.
- Otherwise, inline this brief: *report only defects you can trace to a specific `file:line`
  in the delta, with the failing input; severity CRITICAL / IMPORTANT / DEBT / SUGGESTED /
  QUESTION; state a claim class and do not rank a runtime/data/rendering claim above QUESTION
  when you hold only a static proof; skip anything pre-existing, pedantic, linter-catchable, or
  already handled elsewhere.*
- The diff file, and the working tree as the reviewed state.
- **What changed and why, and the invariant the change is meant to hold.** A reviewer that does
  not know the intended contract cannot recognise a violation of it. This single sentence is the
  difference between a useful pass and a noise generator.
- Where the change touches a boolean condition, a guard, or a precedence chain: ask explicitly
  for the **truth table over every input dimension**, and for the cell that breaks. That is the
  class of bug this gate exists to catch.

**FAIL on any CRITICAL or IMPORTANT finding.** DEBT / SUGGESTED / QUESTION are reported in the
verdict but do not block — the caller decides.

Re-running after a fix is expected: the diff changed, so the marker is stale regardless.

### 4. Project-specific gates

If the repository defines further checks (runtime/browser behaviour, a payload shape, a
migration), run them now. A project skill of the same name overrides this one — see
*Composition* below.

### 5. Verdict and marker

On PASS, write both markers (paths relative to the repo or workspace root that owns
`.claude/`):

```sh
mkdir -p .claude/.commit-gate
git diff --cached | sha256sum | cut -d' ' -f1 > .claude/.commit-gate/last-pass
git rev-parse HEAD                                > .claude/.commit-gate/last-review
```

`last-pass` is what the PreToolUse hook compares against the staged diff. `last-review` is the
baseline for the *next* run — write it only on PASS, so a blocked commit does not silently
shrink the next delta.

> `last-review` records the pre-commit `HEAD`, so the next run re-includes the commit you are
> about to make. That is deliberate and cheap: it is one already-reviewed commit, and it keeps
> the baseline correct without the gate needing to know the sha of a commit that does not exist
> yet.

Return exactly one line:

- `PASS — review: <clean | N low-tier noted> (delta <baseline-short>..HEAD, <N> files)`
- `FAIL — review; <severity> <file:line> <one-line finding>; <what to fix>`

Never PASS with the review skipped on a code delta. When in doubt, FAIL — a blocked commit is
cheap; a logic bug that reaches a merge request costs a review round and a context switch.

## Composition with a project gate

A repository may ship its own `commit-gate-guard` skill with project-specific checks. The
project skill wins on name collision. Keep the split along this line:

| Belongs here (generic) | Belongs in the project skill |
|---|---|
| Baseline resolution, delta assembly | Which pages/flows to exercise |
| The single bounded review pass | Dev-server command, port, credentials |
| Marker files and their meaning | Framework-specific error signatures |
| PASS/FAIL contract | Payload/response shape assertions |

A project skill should state that it runs this review step too, rather than silently dropping it.

## Enforcement hook (opt-in per repository)

`hooks/commit-gate-check.sh` blocks `git commit` when the staged diff does not match
`last-pass`, **or while a tracked verification run is still alive**. It is **opt-in**: it
exits 0 unless `.claude/.commit-gate/` exists in the repository, so installing the plugin
never blocks commits in repos that do not use the gate.

Enable it in a repo with:

```sh
mkdir -p .claude/.commit-gate
```

### In-flight verification

A gate proves nothing until it exits. The hook therefore refuses a commit while any of these
PID files names a live process:

- `.claude/.commit-gate/inflight/<kind>.pid` — write one from whatever launches your gates.
- `$RUN_TRACKED_DIR/run-tracked-<kind>.pid` (default `/tmp`) — the `bg-watch` skill's
  convention, honoured when that skill is installed.

Kinds beginning `dev` or `serve` are long-lived servers, not verification, and never block.
A PID file whose process is gone is stale and does not block either — delete it. No PID
files means nothing to wait for, so this stays invisible in repos that do not use it.

This closes the same hole the marker closes, one step earlier: `last-pass` proves a review
ran, and this proves the run it depended on actually finished.

## Rules

- Verify only — no commit, no amend, no source edit. Writing the two marker files is permitted.
- One agent, one pass. If you want breadth, run the full review tool; this gate stays cheap so
  that it actually gets run.
- Cite evidence: `file:line` and the failing input, never "looks wrong".
- Do not run the full test suite here if the project gates tests at push — say where they run.
