# Orchestration, Subagents and Waiting

## Subagents

- Pin a model on every spawn (hook-enforced by `agent-model-pin.sh`). Forks inherit the parent model.

| Model | Role | Job |
|---|---|---|
| fable | Orchestrator | plans, writes specs, spawns agents, judges reports, integrates |
| haiku | Scout | locates files, symbols, call sites — reports locations, not file dumps |
| sonnet | Researcher | reads docs/source, reports facts, marks anything it could not verify UNVERIFIED |
| sonnet | Builder | codes from a spec, runs the tests |
| opus | Refuter | reviews the diff, re-runs the tests itself |
| opus | Debugger | harder root-cause work only |

`fable` names the orchestrator itself, not a pinnable subagent model — the hook rejects it on a spawn.

**One level of subagents — no nesting.** Only the main session spawns agents. Every brief states:
"Do the work yourself; do NOT spawn sub-agents or background agents." A nested agent is invisible
in the user's agent panel, and its parent exits early and looks stalled — killing that parent
kills the real work with it.

**Every agent returns:** the commands it ran, test counts (files and tests), and pass/fail with the
exit code of each. **Report no status you have not read in the agent's own output** — not from
its brief, not from a prior agent, not inferred; if the output does not state it, say so.

**Scratch-file handoff.** An agent whose result is large writes it to
`.claude/.scratch/<slug>.md` and returns the path plus a short summary; the next agent
reads the file. Bulk text never enters the orchestrator's context.

**Refuter.** The reviewing agent re-runs the builder's tests itself: a builder's "done"
is a claim, and per the Tooling row of the claim-class table in
`verification-standards.md`, a Tooling claim needs a command the claimant ran.

## Orchestration — the main session delegates implementation

- **The main session is an orchestrator: it plans, delegates, verifies and integrates. It does not write feature code itself.** Implementation goes to a subagent, pinned to a model per the role table above.
- Brief each implementation agent with: the specific goal · exact files or URLs in scope · what it may change · what it must verify · what it must not do · the required output format · an output limit · what is already known (so it does not rediscover it). Agents whose file sets overlap are sequenced, never parallel.
- **Verify the task's premise before spending an expensive agent loop on it.** A cheap, direct check against the real system (a curl call, a query, reading the actual file) up front is far cheaper than an authoring pass, a judging pass and a re-scope cycle discovering the premise was wrong. Put the premise check as step 0 of the brief, not as something the agent discovers on its own.
- **Subagents never run state-changing git** — `add`, `commit`, `push`, `stash`, `checkout`, `restore`, `reset`, `rebase`, `merge`, `cherry-pick`, `switch`, `clean` — nor write the orchestrator's compaction checkpoint (`.claude/.compact-gate/**`). The orchestrator owns git state and hands over a clean index. Hook-enforced (`subagent-guard.sh`) by detecting the subagent-only `agent_id` field on the hook payload — this is not prose alone, because prose alone was broken: a builder once ran a project's translation-regenerating npm script followed by a destructive git checkout, silently discarding a sibling agent's uncommitted work. A project can deny additional command patterns via `.claude/subagent-deny.txt` (one ERE per line).
- **Verifiers and judges run against a frozen build — a static build or a deployed target — never the hot-reloading dev server a builder is actively editing.** A builder's in-progress TypeScript error surfaces as an overlay that intercepts the verifier's clicks and produces a false FAIL; a passing check that was actually looking at someone else's mid-edit state is not a check.
- **Gate cadence.** Per wave: run only the affected-scope tests plus the static gates (typecheck, lint, architecture) **in parallel**, on a tree no builder is currently editing. Run the full suite once per local commit, not once per wave — re-running the full suite on a moving tree throws results away the moment the next builder edits a file. **Commit locally after each verified wave** — this is not pushing, and does not require push approval; it turns a wave's result into a `git show` away instead of something reconstructed from transcripts if a later step goes wrong.
- The orchestrator still does the work only it can: building the brief, resolving merge conflicts, judging what came back, running the gates, and recording the change.
- Exception — implement inline only when delegating costs more than doing: a single-line edit, or a fix already fully diagnosed and expressible as one concrete edit. "It would be faster if I just did it" is not that exception.

## Refuter — standing checklist

Every refuter/review pass runs the checklist at `@@KIT@@/context/reference/refuter-checklist.md`
against the diff, in addition to whatever the task-specific brief asks for — recurring defect
patterns are cheaper to check for by habit than to rediscover per review.

## Waiting — never spend the main thread on it

- **Never block a foreground Bash call on a condition or a deadline** (hook-enforced by `bash-guard.sh`). Such a loop holds the main thread for its whole duration and cannot be interrupted; the identical loop with `run_in_background: true` costs nothing and fires one completion notification the moment it exits. **Monitor** gives one notification *per occurrence* — each CI step, each matching log line — for external state the harness cannot see. Settling delays under 10s outside a loop stay allowed.
- **Never poll something the harness already tracks.** Subagents and background commands send their own completion notifications; a `date`/`sleep` loop waiting on one is pure waste.
- **A bounded polling loop is not a completion signal.** `for i in $(seq 1 N); do … break …; sleep 10; done` falls through when its budget runs out, and the line after it prints the same banner either way. What proves the run finished is the process's own exit code — never the loop's.
