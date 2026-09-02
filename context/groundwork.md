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

- Spawn a **dedicated sub-agent** (Agent/Task tool) to write the implementation spec. The main thread does not write it.
- This holds **even when the main thread just did the exploration itself** and feels faster writing it. Skipping it is the common failure: the spec then lives only in the main thread's context, where it is never re-read, and the plan file becomes a running narrative instead of a checkable artifact. Hand the sub-agent your exploration findings; that is what the prompt below is for.
- Target file: `.claude/specs/<slug>.md` in the current repo. Slug = task lowercased, non-alphanumerics → `-`, trimmed, deduped; append `-2`, `-3` if a file already exists.
- The sub-agent writes ONLY that one file and builds NO source.
- Per step the spec records: description · key decision · chosen default · verify method · affected files.
- Hand the sub-agent the prompt and skeleton in the section below.
- **Adversarial spec review (before GATE).** Spawn a SECOND, independent sub-agent (opus —
  judgment tier) that has NOT seen the exploration or the spec-writer's context: it gets only
  the original task, the locked interview decisions, and the spec file path, with read access
  to the tree. Its charter is to prove the spec incomplete — requirements no step covers,
  affected files the steps omit (check callers/consumers of everything touched), `verify:`
  checks that cannot fail, unhandled edge/error paths, premises the current tree contradicts,
  and step-to-step contracts that don't line up. It returns findings only (BLOCKER / GAP /
  NOTE, each with evidence) and edits nothing. The main thread adjudicates, patches the spec,
  then records the adjudicated findings in the spec under a final `## Adversarial review`
  section — BLOCKER/GAP/NOTE entries, or, when the review found nothing, "none found" plus
  the six categories that were checked (list items or table rows both count) — and only then
  proceeds to GATE. The reviewer still edits nothing; the main thread writes the section, so
  what lands is adjudicated rather than raw. One pass; re-check only the fixes — no
  adversary/writer ping-pong. In repos that opt in with `mkdir -p .claude/.spec-gate` this is hook-enforced (`spec-gate-check.sh`).

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
  runs in a subagent (model pinned per the tier rule: haiku read-only / sonnet edits / opus
  judgment) that returns the diagnosis only; the main thread keeps the plan and the integrated
  view.

**Fanning out to parallel agents.** Each agent gets an exclusive file list, and is told
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

### 7. REVIEW

- For any multi-file or multi-agent change, run an **independent review of the integrated
  diff** before shipping. Fix CRITICAL/IMPORTANT findings, then re-run every gate.
- Per-step `verify:` checks prove each step did what it said. They cannot see a contract
  that two steps agreed on wrongly, or a safety promise a docstring makes and the code
  breaks. A change once passed every gate — full suites, lint, typecheck — while
  containing a bug that destroyed files the user had explicitly kept; only reading the
  integrated whole found it.
- One pass is not enough on a large diff, and the review's own findings need the same
  scepticism as any other agent's.

## SPEC phase — sub-agent prompt and template

The sub-agent writes ONE file: the SPEC-phase target spec file (`.claude/specs/<slug>.md`). It builds no source.

### Sub-agent prompt (use verbatim; fill `<task>`, `<spec-file>`, and the locked decisions)

> Write an implementation spec to `<spec-file>` (create the file and its parent
> directory if missing). Do not edit any other file. Do not build.
> For the task "`<task>`" and these locked decisions from the interview:
> `<decisions>` — produce the spec using the skeleton below. For EACH step state:
> description, key decision, chosen default (and why), verify method, affected files.
> Be surgical (§3): no speculative scope, no abstractions for single-use code.
> Return the spec as your final message after writing the file.

### Adversarial reviewer prompt (use verbatim; fill `<task>`, `<spec-file>`, `<decisions>`; model: opus)

> You are an adversarial spec reviewer. Read `<spec-file>` for the task "`<task>`" with locked
> decisions `<decisions>`. You did not write it; assume it is incomplete until proven otherwise.
> Verify its premises against the actual tree — read the code, do not trust the spec's claims.
> Hunt ONLY for: (1) task requirements no step covers; (2) affected files the steps omit —
> check callers/consumers of everything touched; (3) `verify:` checks that cannot fail;
> (4) unhandled edge/error paths within the locked scope; (5) claims the current tree
> contradicts; (6) step-to-step contracts that don't line up. Do not restyle, do not expand
> scope, do not edit any file. Return a findings list — BLOCKER (spec is wrong) / GAP (missing
> step/file/check) / NOTE — each with concrete evidence (file:line or a quoted spec line).
> An empty list means you verified every category and found nothing: say which checks you ran.

### Spec file skeleton

```markdown
# Spec: <task>

## Objective + success criteria
- <what "done" looks like; each criterion independently testable>

## Files to create / change
- <exact paths>

## Open questions / risks
- <unresolved items, name collisions, ambiguities, ordering risks>

## Steps
1. <description>
   - key decision: <the fork this step turns on>
   - default: <chosen default + one-line why>
   - verify: <check that proves the step done>
   - affected files: <paths>
2. <...>

## Final verification gate
- <how to confirm the whole task is correct before declaring done>

## Adversarial review
- <BLOCKER/GAP/NOTE findings with verdicts, or "none found" + the 6 checks run>
```

### Field rules

- **key decision** — the one fork that step turns on; if a step has none, it is probably too granular — merge it.
- **default** — what to do absent further input; must be a concrete choice, not "it depends".
- **verify** — runnable or observable; pairs with the PLAN phase's `verify:` clause.
- **affected files** — exact paths, so the BUILD phase stays surgical.
