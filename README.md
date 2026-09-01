# workflow-kit

[![version](https://img.shields.io/badge/version-0.1.0-blue)](.claude-plugin/plugin.json)

An evidence-first Claude Code workflow, packaged as a plugin. One install gives you:
verification standards with a claim-class proof table, a 7-phase plan/spec/build
methodology with an adversarial spec review, subagent model tiers enforced by hooks,
and the CodeGraph MCP for structural code queries. Extracted from a working setup
after a deep transcript audit tuned each piece against measured waste.

## Install

```bash
claude plugin marketplace add ncoevoet/claude-workflow-kit
claude plugin install workflow-kit@ncoevoet-workflow
```

Restart Claude Code. That's the whole setup — no installer script, nothing copied
into your `~/.claude`.

## What the plugin does

| Component | Mechanism | Effect |
|---|---|---|
| Verification standards | `SessionStart` hook injects [`context/verification-standards.md`](context/verification-standards.md) | Every session starts with the honesty/verification rules and the claim-class table (static / runtime / data / rendering / tooling — each with its one admissible proof) |
| Methodology | Same hook injects [`context/groundwork.md`](context/groundwork.md) | FRAME → INTERVIEW → PLAN → SPEC (sub-agent) → **adversarial spec review** → GATE → BUILD (churn-breaker, delegation threshold, parallel fan-out rules) → REVIEW of the integrated diff |
| Model-pin guard | `PreToolUse` on `Agent\|Task` → [`hooks/agent-model-pin.sh`](hooks/agent-model-pin.sh) | Denies any subagent spawn without an explicit `model`: **haiku** (read-only mechanical) · **sonnet** (mechanical with edits) · **opus** (judgment). Forks exempt |
| Bash guard | `PreToolUse` on `Bash` → [`hooks/bash-guard.sh`](hooks/bash-guard.sh) | Blocks `cd <current-dir> && …` prefixes (cwd persists between calls) and bare symbol-greps in CodeGraph-indexed repos; literal-text searches stay allowed |
| CodeGraph MCP | [`.mcp.json`](.mcp.json) declares `npx -y @colbymchenry/codegraph serve --mcp` | Sub-millisecond, AST-accurate "where is X / what calls Y" queries. `npx` fetches the package on first use — nothing to preinstall |

CodeGraph needs a per-repository index before it answers: run `codegraph init -i`
(or `npx -y @colbymchenry/codegraph init -i`) once in each repo you want indexed.
The bash-guard grep rule only activates where a `.codegraph/` directory exists, so
un-indexed repos behave exactly as before.

**Context cost, stated honestly:** the two injected documents are ~15 KB per session.
That is the same price a CLAUDE.md of that size would pay — the workflow considers it
the highest-yield 15 KB in the budget, but it is not free.

## Companion plugins (optional, same author)

- **review-all** — multi-agent diff review: 10 reviewer axes with pinned model tiers,
  an adversarial verifier pass that kills false positives, per-axis checkpointing
  keyed on HEAD + diff hash.
  `claude plugin marketplace add ncoevoet/claude-review-all && claude plugin install review-all@ncoevoet-review-all`
- **goal-loop** — drives an objective under a hard deterministic oracle enforced by a
  Stop hook, with stuck-detection and run budgets that escalate to a human as
  UNVERIFIED instead of looping forever.
  `claude plugin marketplace add ncoevoet/claude-loop && claude plugin install goal-loop@ncoevoet-loop`
- **claude-markdown-health-check** — audits your `.claude/` tree (skills, hooks,
  settings, memory, plugins) for dead refs, broken frontmatter, budget overflow,
  dormant skills, and context bloat. Run it after any skills/hooks change.
  `claude plugin marketplace add ncoevoet/claude-markdown-health-check && claude plugin install claude-markdown-health-check@ncoevoet-health-check`

## What to adapt

1. **The standards are opinionated** — English-only replies, `deno fmt` for TS/JS,
   a Chrome-DevTools-MCP preference for web debugging. Fork the repo and edit
   [`context/verification-standards.md`](context/verification-standards.md) to your
   stack; the claim-class table and the scope-discipline rules are the parts worth
   keeping verbatim.
2. **The model-pin hook changes behavior immediately** — anything that spawns
   subagents without a `model` gets denied with a message naming the tiers; it
   self-corrects on retry. Too strict on day one? Remove the `Agent|Task` block from
   [`hooks/hooks.json`](hooks/hooks.json) in your fork.
3. **Both guard hooks require `jq`** (present on most dev machines). Without it they
   fail open — nothing breaks, nothing is enforced.

## Why these exact rules (the evidence, briefly)

A deep audit of 27 real sessions found: near-zero mid-task user corrections (the
interview + plan gate works — keep it); rework loops of 5–9 edits to the same file on
the main thread (hence the churn-breaker: 3rd edit → delegate with the failure
output); 12/49 subagent spawns silently inheriting the premium main-loop model and
zero use of the cheap tier (hence the pin hook and the three tiers); 360 redundant
`cd` prefixes and a 105:1 grep-vs-index ratio for symbol lookups (hence the bash
guard); and an interrupted review run that discarded ~42% of its output tokens for
lack of checkpoints (hence review-all's per-axis resume). Every rule in this kit
traces to one of those measurements.

## Uninstall

```bash
claude plugin uninstall workflow-kit@ncoevoet-workflow
```

Everything lives inside the plugin — uninstalling removes the injected context, both
hooks, and the MCP declaration in one step.

## License

MIT
