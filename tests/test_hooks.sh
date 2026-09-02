#!/usr/bin/env bash
# Behavioural tests for the PreToolUse hooks.
# Contract under test: hook reads a PreToolUse JSON payload on stdin and exits
#   0 = allow, 2 = block (message on stderr).
#
# Note: the grep fixtures below are built by concatenation rather than written as
# literals, because bash-guard.sh blocks a symbol-grep in an indexed repo — and this
# repository is itself indexed, so a literal fixture would block the test author.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$HERE/.." && pwd)/hooks"
pass=0; fail=0

# check <name> <expected-exit> <hook> <json>
check() {
    local name="$1" want="$2" hook="$3" json="$4" got
    printf '%s' "$json" | "$HOOKS/$hook" >/dev/null 2>&1
    got=$?
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1)); echo "  ok: $name"
    else
        fail=$((fail + 1)); echo "  FAIL: $name (want exit $want, got $got)"
    fi
}

echo "== agent-model-pin.sh =="
check "spawn without model is blocked"        2 agent-model-pin.sh '{"tool_input":{"subagent_type":"general-purpose"}}'
check "spawn with model is allowed"           0 agent-model-pin.sh '{"tool_input":{"subagent_type":"general-purpose","model":"opus"}}'
check "fork is exempt"                        0 agent-model-pin.sh '{"tool_input":{"subagent_type":"fork"}}'
check "fork without model still exempt"       0 agent-model-pin.sh '{"tool_input":{"subagent_type":"fork","model":""}}'

echo
echo "== bash-guard.sh =="
tmp_plain=$(mktemp -d); tmp_cg=$(mktemp -d); mkdir -p "$tmp_cg/.codegraph"
G="grep"
symbol_grep="$G -rn 'MySym""bol' ."
literal_grep="$G -rn 'two words' ."
check "cd into cwd is blocked"                2 bash-guard.sh "{\"tool_input\":{\"command\":\"cd $tmp_plain && ls\"},\"cwd\":\"$tmp_plain\"}"
check "cd elsewhere is allowed"               0 bash-guard.sh "{\"tool_input\":{\"command\":\"cd /tmp && ls\"},\"cwd\":\"$tmp_plain\"}"
check "plain command is allowed"              0 bash-guard.sh "{\"tool_input\":{\"command\":\"ls -la\"},\"cwd\":\"$tmp_plain\"}"
check "symbol grep blocked when indexed"      2 bash-guard.sh "{\"tool_input\":{\"command\":\"$symbol_grep\"},\"cwd\":\"$tmp_cg\"}"
check "symbol grep allowed when not indexed"  0 bash-guard.sh "{\"tool_input\":{\"command\":\"$symbol_grep\"},\"cwd\":\"$tmp_plain\"}"
check "literal multi-word grep allowed"       0 bash-guard.sh "{\"tool_input\":{\"command\":\"$literal_grep\"},\"cwd\":\"$tmp_cg\"}"

# Foreground waiting: a poll loop or a >=10s delay on the main thread is blocked; the same
# work with run_in_background is not, and short settling delays outside a loop stay allowed.
poll_loop='until ss -ltn | grep -q 4210; do sleep 3; done'
check "foreground poll loop blocked"          2 bash-guard.sh "{\"tool_input\":{\"command\":\"$poll_loop\"},\"cwd\":\"$tmp_plain\"}"
check "same poll loop in background allowed"  0 bash-guard.sh "{\"tool_input\":{\"command\":\"$poll_loop\",\"run_in_background\":true},\"cwd\":\"$tmp_plain\"}"
check "long bare delay blocked"               2 bash-guard.sh "{\"tool_input\":{\"command\":\"sleep 240; gh pr checks 3\"},\"cwd\":\"$tmp_plain\"}"
check "bounded for-loop poll blocked"         2 bash-guard.sh "{\"tool_input\":{\"command\":\"for i in 1 2 3; do pgrep pytest || break; sleep 10; done\"},\"cwd\":\"$tmp_plain\"}"
check "short settling delay allowed"          0 bash-guard.sh "{\"tool_input\":{\"command\":\"kill -9 123; sleep 1; pgrep -f stub\"},\"cwd\":\"$tmp_plain\"}"
check "quoted sleep literal allowed"          0 bash-guard.sh "{\"tool_input\":{\"command\":\"grep -n 'sleep 30' notes.txt\"},\"cwd\":\"$tmp_plain\"}"
check "heredoc writing a wait loop allowed"   0 bash-guard.sh "{\"tool_input\":{\"command\":\"cat > w.sh <<EOF\\nsleep 30\\nEOF\"},\"cwd\":\"$tmp_plain\"}"
rm -rf "$tmp_plain" "$tmp_cg"

echo
echo "== commit-gate-check.sh =="
# Point the bg-watch PID lookup at a scratch dir so a real run on this machine cannot
# leak into the assertions below.
RUN_TRACKED_DIR=$(mktemp -d); export RUN_TRACKED_DIR
# Throwaway git repo with one staged code file.
repo=$(mktemp -d)
(
    cd "$repo" || exit 1
    git init -q .
    git config user.email t@t.t; git config user.name t
    echo "initial" > README.md; git add README.md; git commit -qm init
    mkdir -p src; echo "const a = 1;" > src/a.ts; git add src/a.ts
) >/dev/null 2>&1
J="{\"tool_input\":{\"command\":\"git commit -m x\"},\"cwd\":\"$repo\"}"

check "non-commit command ignored"            0 commit-gate-check.sh "{\"tool_input\":{\"command\":\"git status\"},\"cwd\":\"$repo\"}"
check "gate not enabled -> allowed"           0 commit-gate-check.sh "$J"

mkdir -p "$repo/.claude/.commit-gate"
check "enabled, no marker -> blocked"         2 commit-gate-check.sh "$J"
check "--dry-run ignored"                     0 commit-gate-check.sh "{\"tool_input\":{\"command\":\"git commit --dry-run\"},\"cwd\":\"$repo\"}"

( cd "$repo" && git diff --cached | sha256sum | cut -d' ' -f1 > .claude/.commit-gate/last-pass )
check "marker matches staged diff -> allowed" 0 commit-gate-check.sh "$J"

# In-flight verification blocks the commit even with a matching marker.
mkdir -p "$repo/.claude/.commit-gate/inflight"
sleep 300 & live=$!
echo "$live" > "$repo/.claude/.commit-gate/inflight/test.pid"
check "live gate run -> blocked"              2 commit-gate-check.sh "$J"

mv "$repo/.claude/.commit-gate/inflight/test.pid" "$repo/.claude/.commit-gate/inflight/dev-server.pid"
check "dev/serve kind never blocks"           0 commit-gate-check.sh "$J"

echo "$live" > "$RUN_TRACKED_DIR/run-tracked-build.pid"
check "bg-watch pid file honoured"            2 commit-gate-check.sh "$J"
rm -f "$RUN_TRACKED_DIR/run-tracked-build.pid"

kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
dead=$(bash -c 'echo $$')
echo "$dead" > "$repo/.claude/.commit-gate/inflight/test.pid"
rm -f "$repo/.claude/.commit-gate/inflight/dev-server.pid"
check "stale pid file does not block"         0 commit-gate-check.sh "$J"
rm -rf "$repo/.claude/.commit-gate/inflight"

( cd "$repo" && echo "const b = 2;" >> src/a.ts && git add src/a.ts )
check "stale marker -> blocked"               2 commit-gate-check.sh "$J"

# Docs-only staged diff is never gated, even with a stale marker present.
repo2=$(mktemp -d)
(
    cd "$repo2" || exit 1
    git init -q .
    git config user.email t@t.t; git config user.name t
    echo x > README.md; git add README.md; git commit -qm init
    mkdir -p .claude/.commit-gate
    echo "## docs" >> README.md; git add README.md
) >/dev/null 2>&1
check "docs-only staged -> allowed"           0 commit-gate-check.sh "{\"tool_input\":{\"command\":\"git commit -m d\"},\"cwd\":\"$repo2\"}"
rm -rf "$repo" "$repo2" "$RUN_TRACKED_DIR"

echo
echo "hooks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
