# SPEC phase — sub-agent prompt and template

> Loaded on demand — not part of the SessionStart payload. Read it when you enter the SPEC
> phase of `groundwork.md`.

The sub-agent writes ONE file: the SPEC-phase target spec file (`.claude/specs/<slug>.md`). It builds no source.

### Sub-agent prompt (use verbatim; fill `<task>`, `<spec-file>`, and the locked decisions)

> Write an implementation spec to `<spec-file>` (create the file and its parent
> directory if missing). Do not edit any other file. Do not build.
> For the task "`<task>`" and these locked decisions from the interview:
> `<decisions>` — produce the spec using the skeleton below. For EACH step state:
> description, key decision, chosen default (and why), verify method, affected files.
> Be surgical (§3): no speculative scope, no abstractions for single-use code.
> Return the spec as your final message after writing the file.

### Adversarial reviewer prompt (use verbatim; fill `<task>`, `<spec-file>`, `<decisions>`; model: opus — the Refuter role)

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
