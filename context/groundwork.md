# Groundwork — how I always work

These rules always govern how I work. They are not a command or skill to invoke — they are always in
effect. For trivial edits (typo, rename, obvious one-liner), use judgment and just make the edit. Where the
spec gate is armed, the machine approximation of "trivial" is the first two distinct files in a
two-hour window; a third file requires the spec.

## Principles

1. **Think first** — state assumptions; when interpretations differ, present them, never pick silently; push back when a simpler approach fits; if unclear, stop and name it.
2. **Simplicity** — minimum that solves the problem; nothing speculative; no abstractions for single-use; no error handling for impossible cases. If 200 lines could be 50, rewrite it.
3. **Surgical** — touch only what the task needs; don't refactor code that isn't broken; match existing style; every changed line traces to the request; remove only the orphans your change created, flag unrelated dead code rather than delete it.
4. **Verify** — turn tasks into verifiable goals; give each step an explicit `verify:` check; reproduce bugs with a failing test first, then make it pass; loop until green.

## Non-trivial work — plan before you build

For any non-trivial task (new feature, multi-file change, refactor, or ambiguous scope), run these seven
phases in order before and during the change. Skip the whole flow for trivial edits.

### 1. FRAME

- Restate the task in one line.
- Name the CORE PROBLEM being solved — the underlying need, not the surface request.
- Surface assumptions explicitly; never silently fill ambiguity.
- Apply §1: present multiple interpretations when they exist; push back if a simpler approach fits.

### 2. INTERVIEW

- Loop with the **AskUserQuestion** tool, **max 4 questions per call**, to lock exact scope BEFORE writing code.
- Ask only in-depth, non-obvious questions: scope boundaries, the core problem, key technical/UX decisions, trade-offs, edge cases.
- Offer the simplest sound default as the first option of each question and mark it Recommended.
- Stop the moment further questions would be obvious or speculative. Converge on exact scope — do what's asked, nothing more.

### 3. PLAN

- Produce a numbered plan where EACH step carries an explicit verify check:
  `N. <step> → verify: <check>`
- Stay scope-disciplined (§2 + §3): no speculative features, no abstractions for single-use code, surgical.

### 4. SPEC

- Spawn a **dedicated sub-agent** (Agent/Task tool), a Researcher-class spawn (sonnet), to write the implementation spec. The main thread does not write it.
- This holds **even when the main thread just did the exploration itself** and feels faster writing it. Skipping it is the common failure: the spec then lives only in the main thread's context, where it is never re-read, and the plan file becomes a running narrative instead of a checkable artifact. Hand the sub-agent your exploration findings; that is what the reference file's prompt is for.
- Target file: `.claude/specs/<slug>.md` in the current repo. Slug = task lowercased, non-alphanumerics → `-`, trimmed, deduped; append `-2`, `-3` if a file already exists.
- The sub-agent writes ONLY that one file and builds NO source.
- Per step the spec records: description · key decision · chosen default · verify method · affected files.
- Prompt, adversarial-reviewer prompt, spec skeleton and field rules:
  `@@KIT@@/context/reference/spec-template.md` — read it when you reach this phase.
- **Adversarial spec review (before GATE).** Spawn a SECOND, independent sub-agent (opus — the
  Refuter role) that has NOT seen the exploration or the spec-writer's context: it gets the
  original task, the locked decisions and the spec path, with read access to the tree. Its
  charter is to prove the spec incomplete across six categories — requirements no step covers,
  affected files the steps omit (check callers/consumers of everything touched), `verify:` checks
  that cannot fail, unhandled edge/error paths, premises the tree contradicts, step-to-step
  contracts that don't line up. It returns findings only (BLOCKER / GAP / NOTE, each with
  evidence) and edits nothing. The main thread adjudicates, patches the spec, records the
  adjudicated findings under a final `## Adversarial review` section — or "none found" plus the
  six checks run — and only then proceeds to GATE. One pass; re-check only the fixes, no
  adversary/writer ping-pong. Hook-enforced (`spec-gate-check.sh`) in repos that opt in with
  `mkdir -p .claude/.spec-gate`.

### 5. GATE

- Call **ExitPlanMode** to present the plan for explicit user approval.
- HARD GATE: edit no file until the user approves.
- In opt-in repos `ExitPlanMode` is hook-enforced: approval is refused until the SPEC file and
  its `## Adversarial review` section exist.
- This *uses* native `ExitPlanMode` as its gate — it does not replace native plan mode.

### 6. BUILD

- Only after approval, implement the plan steps in order.
- For each step, run its `verify:` check before starting and again after finishing — verify before you build — looping until it passes (§4).
- Keep changes surgical (§3): every changed line traces to a spec step.
- **Churn-breaker:** a 3rd edit of the same file in one session means the approach is wrong —
  stop iterating, reproduce with a failing test, and hand the failure output to a specialist
  subagent (test-specialist / bug-detective) with an exclusive file list; never attempt edit #4
  on the main thread.
- **Delegation threshold:** an investigation expected to exceed ~30 tool calls or read >10 files
  runs in a subagent (model pinned per the role table in verification-standards.md) that
  returns the diagnosis only; the main thread keeps the plan and the integrated view.

**Fanning out to parallel agents** — exclusive file lists, the stale-brief warning, the
forbidden git verbs, the failing-first evidence rule: `@@KIT@@/context/reference/parallel-agents.md`.
Verify each agent's claims yourself, ideally by breaking something *different* from what it
reported. Reports are evidence, not proof.

### 7. REVIEW

- For any multi-file or multi-agent change, run an **independent review of the integrated
  diff** before shipping. Fix CRITICAL/IMPORTANT findings, then re-run every gate. The
  reviewer re-runs the gates itself, rather than reading the builder's report of them.
- Per-step `verify:` checks prove each step did what it said. They cannot see a contract
  that two steps agreed on wrongly, or a safety promise a docstring makes and the code
  breaks. A change once passed every gate — full suites, lint, typecheck — while
  containing a bug that destroyed files the user had explicitly kept; only reading the
  integrated whole found it.
- One pass is not enough on a large diff, and the review's own findings need the same
  scepticism as any other agent's.

## Compaction — checkpoint before the context is cut

Auto-compaction fires on the harness's clock, not on a task boundary. Left alone it lands
mid-edit and takes with it every piece of working state that lived only in reasoning.

In a repository with a `.claude/.compact-gate/` directory the gate inverts that: automatic
compaction is **blocked** until this session has written a checkpoint, and the `SessionStart`
hook names the file to write — one per session, so sessions sharing a working directory do not
race. Write it when the work is durable — spec on disk, edits saved, sub-agent results
integrated, nothing that matters living only in your reasoning — never mid-edit. Then make one
more small tool call: `PreCompact` only runs on the next compaction attempt, so a session that
checkpoints and goes quiet is never compacted at all. Rewrite it every time; the gate compares
its mtime against the last compaction it let through.
