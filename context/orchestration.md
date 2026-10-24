# Orchestration, Subagents and Waiting

## Subagents

- Pin a model on every spawn (hook-enforced by `agent-model-pin.sh`). Forks inherit the parent model.

| Model | Role | Job |
|---|---|---|
| fable | Main session | plans, writes specs, implements, integrates, judges reports |
| haiku | Scout | locates files, symbols, call sites — reports locations, not file dumps |
| sonnet | Researcher | reads docs/source, reports facts, marks anything it could not verify UNVERIFIED |
| sonnet | Builder | codes one disjoint file set from a spec, in parallel with others |
| opus | Refuter | reviews the diff, re-runs the tests itself |
| opus | Debugger | harder root-cause work only |

`fable` names the main session itself, not a pinnable subagent model — the hook rejects it on a spawn.

Agent types: Scout = `workflow-kit:scout`, Builder = `workflow-kit:builder`, Refuter =
`workflow-kit:refuter`. Prefer them over `general-purpose`: their tool list excludes `Agent`/`Task`,
so nesting is impossible rather than merely forbidden.

**One level of subagents — no nesting.** Only the main session spawns agents; every brief states "Do the work yourself; do NOT spawn sub-agents or background agents." A nested agent is invisible in the agent panel, and killing its stalled-looking parent kills the work.

**Every agent returns:** the commands it ran, test counts (files and tests), and pass/fail with the
exit code of each. **Report no status you have not read in the agent's own output** — not from
its brief, not from a prior agent, not inferred; if the output does not state it, say so. An agent's running/stopped state comes only from its
completion notification or `.claude/.scratch/agents/<id>.json` (written by `agent-status-record.sh`), never from memory.

**Scratch-file handoff.** An agent whose result is large writes it to
`.claude/.scratch/<slug>.md` and returns the path plus a short summary; the next agent
reads the file. Bulk text never enters the main session's context.

**Refuter.** Re-runs the static gates itself (typecheck, lint) — a builder's "done" is a Tooling claim, which needs a command the claimant ran. It runs no test suite.

## Single loop first — delegate by context, not by role

- **The main session implements by default.** One context that plans, builds and integrates beats a chain of agents handing summaries to each other: every handoff is lossy, adds a nested loop's latency, and tightly coupled steps degrade across it. Work that chains on another step's output, touches the same files, or is usually done together stays in one context.
- **Delegate only work whose context can be isolated** — it needs little from the rest of the session and returns a compact result:
  1. **Parallel builders on disjoint file sets** — independent pieces that genuinely run at once. Overlapping file sets are sequenced, never parallel.
  2. **Investigations over the delegation threshold** (~30 tool calls or >10 files) — a Scout or Researcher returns the diagnosis, not the file dumps.
  3. **Independent verification** — refuter, adversarial spec review, debugger on a reproduced failure. A fresh context that has not seen your reasoning is the point.
- **Keep a delegation only if it measures better.** When unsure whether a split pays, the folded version is the default; `@@KIT@@/evals/fold-vs-delegate/` compares the two on cost, latency and outcome.
- When you do delegate, brief the agent with: the specific goal · exact files or URLs in scope · what it may change · what it must verify · what it must not do · the required output format · an output limit · what is already known (so it does not rediscover it).
- **Verify the task's premise before spending an expensive agent loop on it.** A cheap, direct check against the real system (a curl call, a query, reading the actual file) up front is far cheaper than an authoring pass, a judging pass and a re-scope cycle discovering the premise was wrong. Put the premise check as step 0 of the brief, not as something the agent discovers on its own.
- **Subagents never run state-changing git** (`add`, `commit`, `push`, `stash`, `checkout`, `restore`, `reset`, `rebase`, `merge`, `cherry-pick`, `switch`, `clean`) nor write the compaction checkpoint (`.claude/.compact-gate/**`) — hook-enforced by `subagent-guard.sh`; extra patterns via `.claude/subagent-deny.txt`. The main session owns git state.
- **Verifiers run against a frozen build** (static build or deployed target), never a hot-reloading dev server someone is editing.
- **Gate cadence.** Per wave: static gates (typecheck, lint, architecture) in parallel on a tree nobody is editing, then the commit gate's review; **commit locally after each verified wave**. **Tests run in the pre-push hook**, not per wave — except the spec you are writing or fixing, run to see it fail then pass; no pre-push test step → run the suite once before `git push`.
- Rationale and incidents behind these three rules: `@@KIT@@/context/reference/delegation.md`.

## Refuter — standing checklist

Every refuter/review pass runs the checklist at `@@KIT@@/context/reference/refuter-checklist.md`
against the diff, in addition to whatever the task-specific brief asks for — recurring defect
patterns are cheaper to check for by habit than to rediscover per review.

## Waiting — never spend the main thread on it

- **Never block a foreground Bash call on a condition or a deadline** (hook-enforced by `bash-guard.sh`): use `run_in_background: true` for one completion notification, **Monitor** for one per occurrence. Settling delays under 10s outside a loop stay allowed.
- **Never poll what the harness already tracks**, and **a subagent never ends its turn just to wait** — it runs long commands in the foreground under `timeout` and reports once.
- **Every wait on a process is time-bounded** (hook-enforced, foreground and background); a bounded loop falling through is not a completion signal — the process's own exit code is.
- Details, the `pgrep -f` self-match trap, watchdogs and starvation: `@@KIT@@/context/reference/waiting.md` — read it before writing any wait.
