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

**Scratch-file handoff.** An agent whose result is large writes it to
`.claude/.scratch/<slug>.md` and returns the path plus a short summary; the next agent
reads the file. Bulk text never enters the orchestrator's context.

**Refuter.** The reviewing agent re-runs the builder's tests itself: a builder's "done"
is a claim, and per the Tooling row of the claim-class table in
`verification-standards.md`, a Tooling claim needs a command the claimant ran.

## Orchestration — the main session delegates implementation

- **The main session is an orchestrator: it plans, delegates, verifies and integrates. It does not write feature code itself.** Implementation goes to a subagent, pinned to a model per the role table above.
- Brief each implementation agent with: the specific goal · exact files or URLs in scope · what it may change · what it must verify · what it must not do · the required output format · an output limit · what is already known (so it does not rediscover it). Agents whose file sets overlap are sequenced, never parallel.
- **Subagents never run `git add`, `git commit`, `git push`, `git stash` or `git checkout`** — the orchestrator owns git state and hands over a clean index.
- The orchestrator still does the work only it can: building the brief, resolving merge conflicts, judging what came back, running the gates, and recording the change.
- Exception — implement inline only when delegating costs more than doing: a single-line edit, or a fix already fully diagnosed and expressible as one concrete edit. "It would be faster if I just did it" is not that exception.

## Waiting — never spend the main thread on it

- **Never block a foreground Bash call on a condition or a deadline** (hook-enforced by `bash-guard.sh`). Such a loop holds the main thread for its whole duration and cannot be interrupted; the identical loop with `run_in_background: true` costs nothing and fires one completion notification the moment it exits. **Monitor** gives one notification *per occurrence* — each CI step, each matching log line — for external state the harness cannot see. Settling delays under 10s outside a loop stay allowed.
- **Never poll something the harness already tracks.** Subagents and background commands send their own completion notifications; a `date`/`sleep` loop waiting on one is pure waste.
- **A bounded polling loop is not a completion signal.** `for i in $(seq 1 N); do … break …; sleep 10; done` falls through when its budget runs out, and the line after it prints the same banner either way. What proves the run finished is the process's own exit code — never the loop's.
