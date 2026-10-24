# Phases 4–7 — rationale and details

> Loaded on demand — not part of the SessionStart payload. The one-line rules live in
> `context/groundwork.md`; this file carries why they exist and how to apply them at the edges.

## 1–2. FRAME and INTERVIEW

- Never silently fill ambiguity. Converge on exact scope — do what is asked, nothing more.

## 4. SPEC

- Slug: task lowercased, non-alphanumerics → `-`, trimmed and deduped.

- **Why the main thread writes it.** The spec used to be delegated to a writer agent, on the theory
  that a spec living only in the main context is never re-read. The fix for that is the file on
  disk, not a second author: a writer agent receives the exploration as a summary and returns a
  summary of a summary — the lossy-handoff pattern. Writing the file yourself keeps the artifact
  checkable and the context intact.
- **Adversary charter.** Spawn it with the original task, the locked decisions and the spec path,
  read access to the tree, and nothing of your exploration. Six categories: requirements no step
  covers; affected files the steps omit (check callers/consumers of everything touched);
  `verify:` checks that cannot fail; unhandled edge/error paths; premises the tree contradicts;
  step-to-step contracts that don't line up. It returns BLOCKER / GAP / NOTE findings with
  evidence and edits nothing. Re-check only the fixes — no adversary/writer ping-pong.
- **Plan mode.** Plan mode allows writing only the session's plan file. Put the spec, including
  its `## Adversarial review` section, in that file; the ExitPlanMode gate validates the plan text
  itself when it names no spec file. After approval, copy the spec to `.claude/specs/<slug>.md`.

## 5. GATE

- The gate *uses* native `ExitPlanMode` — it does not replace plan mode. In opt-in repos it is
  enforced from the plan text: a named spec path that validates, an inline
  `## Adversarial review`, or a `Spec: none — <reason>` waiver.

## 6. BUILD

- Loop on each step's `verify:` until it passes (§4) — a check run once and ignored is not a check.

- **Churn-breaker.** Three edits to one file is iteration without a model of the problem. Write
  the failing test first; if you are still stuck after it, hand the failure output — not your
  theory — to an opus debugger subagent with an exclusive file list. Its fresh context is the
  value; your hypotheses would anchor it.
- **Delegation threshold.** The main session keeps the plan and the integrated view; the subagent
  keeps the bulk reading out of it.
- **Fan-out.** Verify each agent's claims yourself, ideally by breaking something *different* from
  what it reported. Reports are evidence, not proof.

## 7. REVIEW

- Fix CRITICAL/IMPORTANT findings, then re-run the static gates — tests wait for the pre-push
  hook. The reviewer re-runs those gates itself rather than reading a report of them.
- Per-step `verify:` checks prove each step did what it said. They cannot see a contract that two
  steps agreed on wrongly, or a safety promise a docstring makes and the code breaks. A change
  once passed every gate — full suites, lint, typecheck — while containing a bug that destroyed
  files the user had explicitly kept; only reading the integrated whole found it.
- One pass is not enough on a large diff, and the review's own findings need the same scepticism
  as any other agent's.
