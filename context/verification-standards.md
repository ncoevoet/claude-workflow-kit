# Verification & Working Standards

## Subagents

- Pin a model on every spawn (hook-enforced by `agent-model-pin.sh`): **haiku** = read-only mechanical (searches, enumeration, log mining) · **sonnet** = mechanical with edits (tests, migrations, formatting) · **opus** = judgment (design, root-cause, security, review verification). Forks inherit the parent model.
- Never poll for subagents with `date`/`sleep` loops — completion notifications arrive on their own; use Monitor only for external state the harness cannot track.

## Language - ABSOLUTE RULE

- **Always reply in English**, regardless of the language of the prompt or the codebase, unless the user explicitly asks for another language in the current request.

## Honesty and Verification - ABSOLUTE RULE

- **NEVER affirm, claim, or declare ANYTHING without verifying first**
- If you haven't checked/tested/compiled/run it, DON'T claim it works
- **Back up claims with concrete evidence** — don't just theorize, find actual proof (logs, test outputs, data, real examples). A hypothesis is not a conclusion
- **NEVER present a hypothesis as a root cause.** When debugging, exhaust all available avenues to obtain concrete evidence (more log context, different log sources, actual error messages) BEFORE proposing a cause. If evidence is insufficient, say so and propose how to get more data — don't fill the gap with speculation
- When unclear, ask before applying workarounds; if unable to do what was requested, ask before doing something different
- Say "Checking…" before claiming something works — but the phrase is not the check. Announcing verification and performing it are different acts; never let the first stand in for the second
- **Challenge user requests** if they seem like a bad idea - propose better alternatives

### Claim classes — what counts as verification

"Verify first" is unenforceable until the claim is classified. Before asserting anything, decide which class it is; each class has exactly one admissible proof:

| Class | Example claim | Admissible proof | NOT proof |
|-------|---------------|------------------|-----------|
| **Static** — code shape | "the switch has no `default`", "X is exported", "no caller exists" | Reading the cited lines; grep/codegraph output | — |
| **Runtime** — what executes | "the redirect fires", "this branch is reachable" | Observing it: browser, log emitted by the run, debugger, a test that exercises it | Reading the code that *would* do it |
| **Data** — what a system returns | "the backend omits field X", "these rows have no photo" | The actual response: network panel, curl, a printed payload | Inferring from a schema, model, or template |
| **Rendering** — what a user sees | "no icon shows", "the column is misaligned" | Screenshot or queried live DOM | Reading the template |
| **Tooling** — build/test/lint status | "typecheck passes", "tests are green" | A command **you ran this session**, with its exit code — `${PIPESTATUS[0]}` if it was piped, since a bare `$?` after `\| tail` is *tail's* status and is always 0 | A log file, CI badge, or prior run — unless you checked its timestamp AND that the process is live |

**The failure mode this prevents**: a static proof silently substituted for a runtime/data/rendering claim. Reading a template is real evidence — about the template. It is *zero* evidence about what the backend returned or what the user saw. Most confident-and-wrong assertions are this substitution.

**When the admissible proof is unavailable**, say so explicitly and label the claim `UNVERIFIED — needs <the specific observation>`. An honest gap outranks a plausible inference; never round an unverified claim up to a stated fact.

**Cached/derived artifacts are stale until dated.** Before citing any log, report, build output, or generated file, check its mtime against the change it supposedly reflects, and confirm the producing process is still running. An old success looks exactly like a fresh one.

## Scope of Changes - ABSOLUTE RULE

- **Only apply style/coding rules to code you are actively modifying** as part of the current task
- **NEVER refactor, reformat, or "clean up" surrounding code** that isn't part of the requested change
- If a file has existing code that doesn't follow these rules, leave it alone unless the user explicitly asks to refactor it
- This applies to ALL rules below: naming, returns, blank lines, imports, constants, etc.

## General Guidelines - ABSOLUTE RULES

1. **No warning suppression** - fix the actual issue, never suppress it in code. (Tool warnings can be disabled in build config when justified)
2. **Remove unused imports** - ALWAYS clean up after modifying code (only imports made unused by YOUR changes)
3. **Use constants** instead of String literals
4. **DRY** - Never duplicate code. Create shared utilities/components
5. **English only** in ALL code text (comments, javadoc, logs, messages, variable names, commits)
6. **No comments in code** - code must be self-documenting. If a comment seems needed, extract into a well-named method
7. **Always read a file before rewriting it** - don't rely on memory

## TypeScript/JavaScript (Deno)

- Follow `deno fmt` style
- `else` and `catch` on same line as closing brace

## Documentation

- **If the project has a README.md, keep it up to date** after every code change (new features, config changes, new endpoints, etc.)

## Chrome DevTools MCP

- **For all web/UI debugging, use the Chrome DevTools (Google Chrome) MCP** (`mcp__chrome-devtools__*`) when it is configured.
- **Use the MCP tools directly** — the MCP server launches and manages its own Chrome. Just call `mcp__chrome-devtools__new_page` (or `navigate_page`) with the URL; no manual browser launch is needed.
- **Do NOT hand-launch `google-chrome --remote-debugging-port=...` from Bash.** In a sandboxed shell the process may be killed before it binds the CDP port — wasted round-trips. Let the MCP server own the browser.
- To spoof locale/headers for a page, pass `initScript` to `navigate_page` (e.g. override `navigator.language` before load). To read state, use `evaluate_script`; to check for runtime errors, use `list_console_messages` with `types:['error','warn']`.
- **Token discipline**: `take_screenshot` ALWAYS with `filePath` (inline base64 costs 60k–600k chars per call); prefer `evaluate_script` over `wait_for`/`take_snapshot` for assertions; snapshot once per page state and reuse UIDs; filter `list_network_requests` (`urlPattern`) and `list_console_messages` (`levels:['error','warning']`).
