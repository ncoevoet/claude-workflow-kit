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
echo "== spec-gate-check.sh =="
# Opt-in root 7 levels above the edited file, to prove the walk is uncapped (the commit
# gate stops at 6 because it starts from cwd; this one starts from a source file).
sg=$(mktemp -d)
deep="$sg/a/b/c/d/e/f/g"; mkdir -p "$deep"
SPEC_DIR="$sg/.claude/specs"

ed() { # ed <abs-file> -> Edit payload
    printf '{"tool_input":{"file_path":"%s"},"cwd":"%s"}' "$1" "$sg"
}

# Not enabled anywhere: never blocks, whatever the file count.
check "no opt-in dir -> allowed"              0 spec-gate-check.sh "$(ed "$deep/a.ts")"

mkdir -p "$sg/.claude/.spec-gate"
export WORKFLOW_SPEC_GATE_FREE_FILES=0

# Enabled, no spec at all.
check "opt-in, no spec -> blocked"            2 spec-gate-check.sh "$(ed "$deep/a.ts")"
check "docs are never gated"                  0 spec-gate-check.sh "$(ed "$sg/README.md")"
check ".claude/ files never gated"            0 spec-gate-check.sh "$(ed "$sg/.claude/settings.json")"
# The plan gate needs a prior edit in this repo before it will fire (see the ExitPlanMode
# block further down for why); prime it so this assertion tests the spec check, not that.
printf '%s\t%s\n' "$(date +%s)" "$deep/seed.ts" > "$sg/.claude/.spec-gate/touched"
check "ExitPlanMode, no spec -> blocked"      2 spec-gate-check.sh "{\"tool_input\":{},\"cwd\":\"$sg\"}"
rm -f "$sg/.claude/.spec-gate/touched"

# Writing the spec must never be blocked, including when it creates the directory,
# and including with FREE_FILES=0 (self-lockout regression).
check "spec write allowed (creates dir)"      0 spec-gate-check.sh "$(ed "$SPEC_DIR/x.md")"
mkdir -p "$SPEC_DIR"

# A spec with no adversarial-review section does not satisfy the gate.
printf '# Spec: x\n\n## Steps\n1. do it\n' > "$SPEC_DIR/x.md"
printf '%s\n' "$SPEC_DIR/x.md" > "$sg/.claude/.spec-gate/current"
check "spec without review section -> blocked" 2 spec-gate-check.sh "$(ed "$deep/a.ts")"

# Findings-style section passes. Uses BLOCKER via concatenation so this file does not
# itself look like a findings list to any future scanner.
SEV="BLOCK""ER"
{ printf '# Spec: x\n\n## Adversarial review\n\n'; printf -- '- %s: something is wrong\n' "$SEV"; printf -- '- GAP: something is missing\n- NOTE: minor\n'; } > "$SPEC_DIR/x.md"
check "review section with findings -> allowed" 0 spec-gate-check.sh "$(ed "$deep/a.ts")"

# "none found" needs six enumerated checks; two is not enough.
{ printf '# Spec: x\n\n## Adversarial review\n\nVerified, none found.\n\n'; printf -- '- requirements\n- files\n'; } > "$SPEC_DIR/x.md"
check "none-found with 2 checks -> blocked"   2 spec-gate-check.sh "$(ed "$deep/a.ts")"
{ printf '# Spec: x\n\n## Adversarial review\n\nVerified, none found.\n\n'; printf -- '- requirements\n- files\n- verify checks\n- edge paths\n- premises\n- contracts\n'; } > "$SPEC_DIR/x.md"
check "none-found with 6 checks -> allowed"   0 spec-gate-check.sh "$(ed "$deep/a.ts")"

# A markdown table is this repo's house style for structured lists and must count.
{ printf '# Spec: x\n\n## Adversarial review\n\nVerified, none found.\n\n'; printf '| # | check |\n|---|---|\n'; for i in 1 2 3 4 5 6; do printf '| %s | c%s |\n' "$i" "$i"; done; } > "$SPEC_DIR/x.md"
check "none-found as 6-row table -> allowed"  0 spec-gate-check.sh "$(ed "$deep/a.ts")"

# Pointer hygiene: expired, or naming a spec outside the resolved root, does not unlock.
{ printf '# Spec: x\n\n## Adversarial review\n\n'; printf -- '- %s: x\n' "$SEV"; } > "$SPEC_DIR/x.md"
touch -d '-2 days' "$sg/.claude/.spec-gate/current"
check "expired pointer -> blocked"            2 spec-gate-check.sh "$(ed "$deep/a.ts")"
printf '%s\n' "$SPEC_DIR/x.md" > "$sg/.claude/.spec-gate/current"
other=$(mktemp -d); mkdir -p "$other/.claude/specs"
cp "$SPEC_DIR/x.md" "$other/.claude/specs/x.md"
printf '%s\n' "$other/.claude/specs/x.md" > "$sg/.claude/.spec-gate/current"
check "pointer outside root -> blocked"       2 spec-gate-check.sh "$(ed "$deep/a.ts")"
printf '%s\n' "$SPEC_DIR/x.md" > "$sg/.claude/.spec-gate/current"

# Free-file budget: first N distinct files pass without any spec.
rm -f "$sg/.claude/.spec-gate/current" "$sg/.claude/.spec-gate/touched"
WORKFLOW_SPEC_GATE_FREE_FILES=2 check "1st file free"  0 spec-gate-check.sh "$(ed "$deep/f1.ts")"
WORKFLOW_SPEC_GATE_FREE_FILES=2 check "2nd file free"  0 spec-gate-check.sh "$(ed "$deep/f2.ts")"
WORKFLOW_SPEC_GATE_FREE_FILES=2 check "3rd file gated" 2 spec-gate-check.sh "$(ed "$deep/f3.ts")"

# Kill switch.
WORKFLOW_SPEC_GATE=off check "kill switch -> allowed" 0 spec-gate-check.sh "$(ed "$deep/a.ts")"

# Write creating a not-yet-existing directory must still resolve (readlink -m, not -f).
check "write into missing dir -> blocked"     2 spec-gate-check.sh "$(ed "$deep/brand/new/dir/n.ts")"

# ExitPlanMode has no file path, so it cannot know which repo a plan targets: it resolves the
# root from cwd. Blocking on that alone falsely refuses a plan whose work lives in a DIFFERENT
# repo, whenever the shell happens to sit in an opt-in one. Only gate it once the session has
# actually edited something here.
rm -f "$sg/.claude/.spec-gate/touched" "$sg/.claude/.spec-gate/current"
check "ExitPlanMode, nothing touched -> allowed" 0 spec-gate-check.sh "{\"tool_input\":{},\"cwd\":\"$sg\"}"
printf '%s\t%s\n' "$(date +%s)" "$deep/a.ts" > "$sg/.claude/.spec-gate/touched"
check "ExitPlanMode after an edit -> blocked"    2 spec-gate-check.sh "{\"tool_input\":{},\"cwd\":\"$sg\"}"
printf '%s\t%s\n' "$((`date +%s` - 99999))" "$deep/a.ts" > "$sg/.claude/.spec-gate/touched"
check "ExitPlanMode, stale touches -> allowed"   0 spec-gate-check.sh "{\"tool_input\":{},\"cwd\":\"$sg\"}"
rm -f "$sg/.claude/.spec-gate/touched"

unset WORKFLOW_SPEC_GATE_FREE_FILES
rm -rf "$sg" "$other"

echo
echo "hooks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
