# Groundwork — how I always work

These rules always govern how I work. They are not a command or skill to invoke — they are always in
effect. For trivial edits (typo, rename, obvious one-liner), skip the planning flow below and just make the
edit — the pre-edit contract still applies to ticket work, trivial edits included. Where the
spec gate is armed, the machine approximation of "trivial" is the first two distinct files in a
two-hour window; a third file requires the spec.

## Principles

1. **Think first** — state assumptions; when interpretations differ, present them, never pick silently; push back when a simpler approach fits; if unclear, stop and name it. An ad-hoc request (not a ticket) with more than one plausible reading — which field, forms or apps; recommend vs audit vs fix — gets restated in 2–3 bullets (what, where, which approach) before any action.
2. **Simplicity** — minimum that solves the problem; nothing speculative; no abstractions for single-use; no error handling for impossible cases. If 200 lines could be 50, rewrite it.
3. **Surgical** — touch only what the task needs; don't refactor code that isn't broken; match existing style; every changed line traces to the request; remove only the orphans your change created, flag unrelated dead code rather than delete it.
4. **Verify** — turn tasks into verifiable goals; give each step an explicit `verify:` check; reproduce bugs with a failing test first, then make it pass; loop until green.

## Pre-edit contract — wait for the user's OK

Before editing anything for a ticket — trivial edits included, and whether the edit is yours or a
subagent's — list, then **stop and wait for the user's explicit OK**:

1. the exact files, and the fields/symbols in them, that will change;
2. what will NOT change (adjacent files, behaviour, data, contracts deliberately left alone);
3. the domain rules being assumed (business rules, data invariants, API contracts), each one marked
   verified (with its source) or assumed.

The OK covers that list only. A file, field or rule outside it needs a new list and a new OK — never
widen scope silently.

## Non-trivial work — plan before you build

For any non-trivial task (new feature, multi-file change, refactor, or ambiguous scope), run these seven
phases in order before and during the change. Skip the whole flow for trivial edits.

### 1. FRAME

- Restate the task in one line and name the CORE PROBLEM — the underlying need, not the surface request.
- Surface assumptions; apply §1 (interpretations, push back on a simpler path).

### 2. INTERVIEW

- Loop with **AskUserQuestion** (max 4 questions per call) to lock exact scope BEFORE writing code — only in-depth, non-obvious questions: scope boundaries, key technical/UX decisions, trade-offs, edge cases.
- Simplest sound default first, marked Recommended. Stop once further questions would be obvious or speculative.

### 3. PLAN

- Produce a numbered plan where EACH step carries an explicit verify check:
  `N. <step> → verify: <check>`
- Stay scope-disciplined (§2 + §3): no speculative features, no abstractions for single-use code, surgical.

### 4. SPEC

- **The main thread writes the spec itself**, from its own exploration — handing it to a writer
  agent only re-transmits that context, lossily. Target: `.claude/specs/<slug>.md` (slug = task
  lowercased, non-alphanumerics → `-`, deduped; `-2`, `-3` on collision). In plan mode, write it
  into the session's plan file and copy it to `.claude/specs/` after approval.
- Per step: description · key decision · chosen default · verify method · affected files.
- **Adversarial spec review (before GATE).** An independent opus subagent (Refuter role) that has
  NOT seen your exploration tries to prove the spec incomplete across six categories; you
  adjudicate, patch, and record the outcome under a final `## Adversarial review` section — or
  "none found" plus the six checks run. One pass. Hook-enforced (`spec-gate-check.sh`) in repos
  that opt in with `mkdir -p .claude/.spec-gate`.
- Skeleton, field rules and the adversary prompt: `@@KIT@@/context/reference/spec-template.md`.

### 5. GATE

- Call **ExitPlanMode** for explicit approval; edit no file until the user approves. In opt-in
  repos the plan must name its spec, carry its own `## Adversarial review`, or say
  `Spec: none — <reason>`.

### 6. BUILD

- Implement the plan steps in order, in the main session; run each step's `verify:` before and
  after; every changed line traces to a spec step (§3).
- **Churn-breaker:** a 3rd edit of the same file in one session means the approach is wrong —
  stop and reproduce with a failing test before edit #4.
- **Delegation threshold:** an investigation expected to exceed ~30 tool calls or read >10 files
  runs in a subagent (model pinned per the role table in `orchestration.md`) that returns the
  diagnosis only.
- Parallel fan-out rules: `@@KIT@@/context/reference/parallel-agents.md`.

### 7. REVIEW

- Any multi-file change gets an **independent review of the integrated diff** (refuter) before
  shipping; fix CRITICAL/IMPORTANT, re-run the static gates.

Rationale, worked failures and the plan-mode details for phases 4–7:
`@@KIT@@/context/reference/build-phases.md` — read it when you reach SPEC.

## Compaction — checkpoint before the context is cut

In a repository with `.claude/.compact-gate/`, automatic compaction is blocked until this session
writes the checkpoint file the `SessionStart` hook named. Write it only when the work is durable
(spec on disk, edits saved, results integrated), then make one more small tool call. Details:
`@@KIT@@/context/reference/compaction.md`.
