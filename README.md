# workflow-kit

[![version](https://img.shields.io/badge/version-0.4.0-blue)](.claude-plugin/plugin.json)

An evidence-first Claude Code workflow, packaged as a plugin. One install gives you:
verification standards with a claim-class proof table, a 7-phase plan/spec/build
methodology with an adversarial spec review, a pre-commit review gate over everything
changed since the last review that also refuses to commit while verification is still
running, subagent model tiers enforced by hooks, a guard against burning the main thread
on foreground waiting, and the
[CodeGraph](https://github.com/colbymchenry/codegraph) MCP for structural code
queries. Extracted from a working setup after a deep transcript audit tuned each
piece against measured waste.

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
| Verification standards | `SessionStart` → [`hooks/inject-context.sh`](hooks/inject-context.sh) injects [`context/verification-standards.md`](context/verification-standards.md) | Every session starts with the honesty/verification rules and the claim-class table (static / runtime / data / rendering / tooling — each with its one admissible proof) |
| Methodology | Same hook injects [`context/groundwork.md`](context/groundwork.md) | FRAME → INTERVIEW → PLAN → SPEC (sub-agent) → **adversarial spec review** → GATE → BUILD (churn-breaker, delegation threshold, parallel fan-out rules) → REVIEW of the integrated diff |
| Model-pin guard | `PreToolUse` on `Agent\|Task` → [`hooks/agent-model-pin.sh`](hooks/agent-model-pin.sh) | Denies any subagent spawn without an explicit `model`: **haiku** (read-only mechanical) · **sonnet** (mechanical with edits) · **opus** (judgment). Forks exempt |
| Bash guard | `PreToolUse` on `Bash` → [`hooks/bash-guard.sh`](hooks/bash-guard.sh) | Blocks `cd <current-dir> && …` prefixes (cwd persists between calls), bare symbol-greps in CodeGraph-indexed repos, and **foreground waiting** — an `until`/`while` poll loop or a `sleep` of 10s or more on the main thread. The message names the fix: the same command with `run_in_background: true` for one completion notification, or `Monitor` for one per occurrence. Literal-text searches, background runs and short settling delays stay allowed |
| Commit gate | [`skills/commit-gate-guard`](skills/commit-gate-guard/SKILL.md) + `PreToolUse` on `Bash` → [`hooks/commit-gate-check.sh`](hooks/commit-gate-check.sh) | One small, bounded review pass over everything changed **since the last recorded review** — not just the staged diff — before `git commit`. Blocks on a CRITICAL/IMPORTANT finding, and blocks while a tracked verification run is still alive (`.claude/.commit-gate/inflight/<kind>.pid`, or `bg-watch`'s `run-tracked-<kind>.pid`). **Opt-in per repo**: the hook stays out of the way until you `mkdir -p .claude/.commit-gate` |
| Spec gate | `PreToolUse` on `ExitPlanMode` and `Edit|Write` → [`hooks/spec-gate-check.sh`](hooks/spec-gate-check.sh) | Refuses plan approval, and the third source file in two hours, until the SPEC phase produced `.claude/specs/<slug>.md` carrying an `## Adversarial review` section — BLOCKER/GAP/NOTE entries, or "none found" plus the six checks run. Structural, not semantic: it proves the artifact exists, not that the adversary was good, so it stops silent skipping rather than deliberate circumvention. **Opt-in per repo**: `mkdir -p .claude/.spec-gate`. Tunable: `WORKFLOW_SPEC_GATE_FREE_FILES` (2), `WORKFLOW_SPEC_GATE_WINDOW_MIN` (120), `WORKFLOW_SPEC_GATE_TTL_MIN` (480), `WORKFLOW_SPEC_GATE=off`. `ExitPlanMode` carries no file path, so it resolves the repo from `cwd` then `$CLAUDE_PROJECT_DIR` and stays silent if neither is inside the opt-in repo |
| [CodeGraph](https://github.com/colbymchenry/codegraph) MCP | [`.mcp.json`](.mcp.json) declares `npx -y @colbymchenry/codegraph serve --mcp` | Sub-millisecond, AST-accurate "where is X / what calls Y" queries. `npx` fetches the package on first use — nothing to preinstall |

CodeGraph needs a per-repository index before it answers: run `codegraph init -i`
(or `npx -y @colbymchenry/codegraph init -i`) once in each repo you want indexed.
The bash-guard grep rule only activates where a `.codegraph/` directory exists, so
un-indexed repos behave exactly as before.

**Context cost, stated honestly:** the two injected documents are ~15 KB per session.
That is the same price a CLAUDE.md of that size would pay — the workflow considers it
the highest-yield 15 KB in the budget, but it is not free.

## Companion plugins (optional, same author)

- **[review-all](https://github.com/ncoevoet/claude-review-all)** — multi-agent diff
  review: 10 reviewer axes with pinned model tiers, an adversarial verifier pass that
  kills false positives, per-axis checkpointing keyed on HEAD + diff hash.
  `claude plugin marketplace add ncoevoet/claude-review-all && claude plugin install review-all@ncoevoet-review-all`
- **[goal-loop](https://github.com/ncoevoet/claude-loop)** — drives an objective under
  a hard deterministic oracle enforced by a Stop hook, with stuck-detection and run
  budgets that escalate to a human as UNVERIFIED instead of looping forever.
  `claude plugin marketplace add ncoevoet/claude-loop && claude plugin install goal-loop@ncoevoet-loop`
- **[claude-markdown-health-check](https://github.com/ncoevoet/claude-markdown-health-check)**
  — audits your `.claude/` tree (skills, hooks, settings, memory, plugins) for dead
  refs, broken frontmatter, budget overflow, dormant skills, and context bloat. Run it
  after any skills/hooks change.
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
3. **The guard hooks require `jq`** (present on most dev machines). Without it they
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

Two rules were added after a second audit, of 8 days across 12 repos. **Foreground waiting**
was the largest single sink: 168 Bash calls carrying a `sleep`, holding the main thread for
**244 minutes** in total (mean 87s, max 10 min), plus 71 of 174 background shells whose only
job was to wait — against 8 uses of the `Monitor` tool in the same period. Hence the wait
guard and the Waiting section. **In-flight verification** came from the gate's own logic: a
`last-pass` marker proves a review ran, but nothing proved the test run that review depended
on had finished, and a bounded `for i in $(seq 1 N)` poll loop prints its "finished" banner
whether or not the process exited.

The commit gate was added after a measured miss of a different kind: a full review ran, its
findings were fixed, and the *fix* introduced a boolean-precedence bug that reached the merge
request. Typecheck, lint, the browser check and the whole spec suite were green — the specs
having been written in the same pass, under the same wrong assumption. A review only ever sees
the code as it was when it ran; the gate closes the window after it.

## Tests

```bash
./tests/run.sh
```

Deterministic, no network, no API key. Validates every JSON manifest, checks that each hook
referenced by `hooks.json` exists and is executable, checks skill frontmatter, runs `bash -n`
and `shellcheck`, then exercises all four hooks end-to-end against their real stdin/exit-code
contract — including a throwaway git repo for the commit gate (opt-in off, no marker, stale
marker, matching marker, docs-only, `--dry-run`).

## Uninstall

```bash
claude plugin uninstall workflow-kit@ncoevoet-workflow
```

Everything lives inside the plugin — uninstalling removes the injected context, every
hook, the commit gate, and the MCP declaration in one step.

## License

MIT
