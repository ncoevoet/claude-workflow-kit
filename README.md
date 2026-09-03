# workflow-kit

[![version](https://img.shields.io/badge/version-0.6.0-blue)](.claude-plugin/plugin.json)

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
| Orchestration | Same document | The main session plans, delegates, verifies and integrates — it does not write feature code itself. Each implementation agent is briefed with the files it owns, the files it must not touch, the invariants to hold and the commands to run; overlapping file sets are sequenced, never parallel; and subagents never touch git state |
| Methodology | Same hook injects [`context/groundwork.md`](context/groundwork.md) | FRAME → INTERVIEW → PLAN → SPEC (sub-agent) → **adversarial spec review** → GATE → BUILD (churn-breaker, delegation threshold, parallel fan-out rules) → REVIEW of the integrated diff |
| Model-pin guard | `PreToolUse` on `Agent\|Task` → [`hooks/agent-model-pin.sh`](hooks/agent-model-pin.sh) | Denies any subagent spawn without an explicit `model`: **haiku** (read-only mechanical) · **sonnet** (mechanical with edits) · **opus** (judgment). Forks exempt |
| Bash guard | `PreToolUse` on `Bash` → [`hooks/bash-guard.sh`](hooks/bash-guard.sh) | Blocks `cd <current-dir> && …` prefixes (cwd persists between calls), bare symbol-greps in CodeGraph-indexed repos, and **foreground waiting** — an `until`/`while` poll loop or a `sleep` of 10s or more on the main thread. The message names the fix: the same command with `run_in_background: true` for one completion notification, or `Monitor` for one per occurrence. Literal-text searches, background runs and short settling delays stay allowed |
| Commit gate | [`skills/commit-gate-guard`](skills/commit-gate-guard/SKILL.md) + `PreToolUse` on `Bash` → [`hooks/commit-gate-check.sh`](hooks/commit-gate-check.sh) | One small, bounded review pass over everything changed **since the last recorded review** — not just the staged diff — before `git commit`. Blocks on a CRITICAL/IMPORTANT finding, and blocks while a tracked verification run is still alive (`.claude/.commit-gate/inflight/<kind>.pid`, or `bg-watch`'s `run-tracked-<kind>.pid`). **Opt-in per repo**: the hook stays out of the way until you `mkdir -p .claude/.commit-gate` |
| Spec gate | `PreToolUse` on `ExitPlanMode` and `Edit|Write` → [`hooks/spec-gate-check.sh`](hooks/spec-gate-check.sh) | Refuses plan approval, and the third source file in two hours, until the SPEC phase produced `.claude/specs/<slug>.md` carrying an `## Adversarial review` section — BLOCKER/GAP/NOTE entries, or "none found" plus the six checks run. Structural, not semantic: it proves the artifact exists, not that the adversary was good, so it stops silent skipping rather than deliberate circumvention. **Opt-in per repo**: `mkdir -p .claude/.spec-gate`. Tunable: `WORKFLOW_SPEC_GATE_FREE_FILES` (2), `WORKFLOW_SPEC_GATE_WINDOW_MIN` (120), `WORKFLOW_SPEC_GATE_TTL_MIN` (480), `WORKFLOW_SPEC_GATE=off`. `ExitPlanMode` carries no file path, so it resolves the repo from `cwd` and only fires once the session has already edited a file there — otherwise a plan whose work targets a *different* repo is falsely blocked whenever the shell sits in an opt-in one. The `Edit|Write` half is the load-bearing one |
| [CodeGraph](https://github.com/colbymchenry/codegraph) MCP | [`.mcp.json`](.mcp.json) declares `npx -y @colbymchenry/codegraph serve --mcp` | Sub-millisecond, AST-accurate "where is X / what calls Y" queries. `npx` fetches the package on first use — nothing to preinstall |
| Prove | Standalone script — not hook-wired → [`tools/prove.sh`](tools/prove.sh) | Deliberately breaks the file a check watches, confirms the check goes red, restores the file, confirms it goes green again. Answers "a check never observed failing has been run, not verified" ([`context/verification-standards.md`](context/verification-standards.md)) |

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

## Why these rules

Each rule answers a failure that actually happened, not a preference:

- **Interview + plan gate** — mid-task corrections were already rare with it. Kept.
- **Churn-breaker (3rd edit of a file → delegate)** — long rework loops on the main thread kept
  not converging; a fresh agent handed the failure output did.
- **Subagent model tiers, hook-enforced** — spawns silently inherited the main loop's premium
  model and the cheap tier went unused. A default nobody sets is a default nobody notices.
- **Bash guard** — `cd` into the current directory is always redundant, and a symbol grep in an
  indexed repo is the slower, less accurate way to ask a question the index already answers.
- **Foreground-wait guard** — waiting was the largest single sink of main-thread time, while the
  tool built for it went almost unused. A blocked foreground call cannot even be interrupted.
- **In-flight block** — a recorded PASS proves a review ran, not that the test run it depended on
  had finished; a bounded poll loop prints its "finished" banner whether or not the process exited.
- **Commit gate** — a review ran, its findings were fixed, and the *fix* introduced a bug that
  reached the merge request with typecheck, lint, browser check and the full suite green, the specs
  having been written in the same pass under the same wrong assumption. A review only ever sees the
  code as it was when it ran; the gate closes the window after it.
- **Spec gate** — SPEC and its adversarial review were the only phases in this methodology with no
  enforcement behind them, and they were the ones that got skipped. Every rule with a hook was
  followed, including when it blocked and forced another approach. Prose lost; hooks won.

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
