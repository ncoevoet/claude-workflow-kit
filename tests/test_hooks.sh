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

# check_stderr <name> <expected-exit> <hook> <json> <substring> — as check, but also asserts
# the hook's stderr contains <substring>, so a block message's actual text is pinned, not just
# its exit code.
check_stderr() {
    local name="$1" want="$2" hook="$3" json="$4" needle="$5" got err
    err=$(printf '%s' "$json" | "$HOOKS/$hook" 2>&1 >/dev/null)
    got=$?
    if [ "$got" != "$want" ]; then
        fail=$((fail + 1)); echo "  FAIL: $name (want exit $want, got $got)"
    elif ! grep -qF -- "$needle" <<<"$err"; then
        fail=$((fail + 1)); echo "  FAIL: $name (stderr missing '$needle')"
    else
        pass=$((pass + 1)); echo "  ok: $name"
    fi
}

# check_env <name> <expected-exit> <hook> <json> <VAR=VAL>... — as check, but with the
# named variables set for the hook process only, so a kill switch or a tuning knob can be
# exercised without leaking into the rest of the run.
check_env() {
    local name="$1" want="$2" hook="$3" json="$4" got
    shift 4
    printf '%s' "$json" | env "$@" "$HOOKS/$hook" >/dev/null 2>&1
    got=$?
    if [ "$got" = "$want" ]; then
        pass=$((pass + 1)); echo "  ok: $name"
    else
        fail=$((fail + 1)); echo "  FAIL: $name (want exit $want, got $got)"
    fi
}

# check_no_jq <name> <expected-exit> <hook> <json> — as check, but runs the hook under a
# minimal PATH (a mktemp -d dir holding symlinks to bash and cat only), so `command -v jq`
# genuinely fails and the fail-open guard is exercised for real. Stripping PATH entirely (or
# shadowing jq with an exported shell function) both measured wrong: an empty PATH also
# removes cat, and `command -v` resolves a shadowed shell function, so the guard never fires.
check_no_jq() {
    local name="$1" want="$2" hook="$3" json="$4" got tmpbin
    tmpbin=$(mktemp -d)
    ln -s "$(command -v bash)" "$tmpbin/bash"
    ln -s "$(command -v cat)" "$tmpbin/cat"
    printf '%s' "$json" | env PATH="$tmpbin" "$HOOKS/$hook" >/dev/null 2>&1
    got=$?
    rm -rf "$tmpbin"
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
check "model haiku is allowed"                0 agent-model-pin.sh '{"tool_input":{"model":"haiku"}}'
check "model sonnet is allowed"               0 agent-model-pin.sh '{"tool_input":{"model":"sonnet"}}'
check "model fable is blocked"                2 agent-model-pin.sh '{"tool_input":{"model":"fable"}}'
check "model banana is blocked"               2 agent-model-pin.sh '{"tool_input":{"model":"banana"}}'
check "fork exempt even with model fable"     0 agent-model-pin.sh '{"tool_input":{"subagent_type":"fork","model":"fable"}}'
check_stderr "no-model message says no explicit model" 2 agent-model-pin.sh \
    '{"tool_input":{"subagent_type":"general-purpose"}}' \
    "BLOCKED: subagent spawn without an explicit model."
check_stderr "invalid-model message echoes the offending value" 2 agent-model-pin.sh \
    '{"tool_input":{"model":"banana"}}' \
    "'banana' is not a valid subagent model"
check_stderr "fable message names the orchestrator" 2 agent-model-pin.sh \
    '{"tool_input":{"model":"fable"}}' \
    "fable is the orchestrator's model"
check_no_jq "valid payload allowed without jq" 0 agent-model-pin.sh '{"tool_input":{"model":"haiku"}}'

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

# Monorepo: the gate directory is anchored on the repository ROOT, so a nested one left in a
# sub-project cannot shadow it. Both halves of the gate must resolve the same directory —
# the skill writes the marker at the root and the hook has to read it there no matter which
# directory the commit runs from. Before this was anchored, a commit run from the sub-project
# read the nested marker: `last-pass` over-blocked, and a nested `last-review` would have
# silently shrunk the next delta review.
mono=$(mktemp -d)
(
    cd "$mono" || exit 1
    git init -q .
    git config user.email t@t.t; git config user.name t
    echo initial > README.md; git add README.md; git commit -qm init
    mkdir -p apps/ng/src; echo "const a = 1;" > apps/ng/src/a.ts; git add apps/ng/src/a.ts
    mkdir -p .claude/.commit-gate apps/ng/.claude/.commit-gate
    git diff --cached | sha256sum | cut -d' ' -f1 > .claude/.commit-gate/last-pass
    echo "0000000000000000000000000000000000000000000000000000000000000000" \
        > apps/ng/.claude/.commit-gate/last-pass
) >/dev/null 2>&1
check "root marker wins from the repo root" 0 commit-gate-check.sh \
    "{\"tool_input\":{\"command\":\"git commit -m x\"},\"cwd\":\"$mono\"}"
check "root marker wins from a sub-project" 0 commit-gate-check.sh \
    "{\"tool_input\":{\"command\":\"git commit -m x\"},\"cwd\":\"$mono/apps/ng\"}"
# And the root marker still has to be right — the anchoring must not turn into "always allow".
echo bad > "$mono/.claude/.commit-gate/last-pass"
check "wrong root marker still blocks from a sub-project" 2 commit-gate-check.sh \
    "{\"tool_input\":{\"command\":\"git commit -m x\"},\"cwd\":\"$mono/apps/ng\"}"

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

# --- the gate follows the repo the commit RUNS in, not the session cwd ----------------
# `cd /other-repo && git commit` commits somewhere else entirely. Resolving from cwd alone
# blocks repos that never opted in, and — worse — silently skips the gate when the commit
# lands in an opt-in repo from a session sitting elsewhere.
# Fixtures: $repo is opt-in with a stale marker (-> blocked), $plain never opted in (-> allowed),
# so the exit code alone says which repository the hook resolved.
plain=$(mktemp -d)
(
    cd "$plain" || exit 1
    git init -q .
    git config user.email t@t.t; git config user.name t
    echo x > README.md; git add README.md; git commit -qm init
    mkdir -p src; echo "const c = 3;" > src/c.ts; git add src/c.ts
) >/dev/null 2>&1

cg() { # cg <payload-cwd> <command> -> PreToolUse payload
    printf '{"tool_input":{"command":"%s"},"cwd":"%s"}' "$2" "$1"
}

check "cd to a non-gated repo -> allowed"     0 commit-gate-check.sh "$(cg "$repo"  "cd $plain && git commit -m x")"
check "cd to the gated repo -> blocked"       2 commit-gate-check.sh "$(cg "$plain" "cd $repo && git commit -m x")"
check "semicolon separator honoured"          0 commit-gate-check.sh "$(cg "$repo"  "cd $plain; git commit -m x")"
check "single-quoted cd path honoured"        0 commit-gate-check.sh "$(cg "$repo"  "cd '$plain' && git commit -m x")"
check "double-quoted cd path honoured"        2 commit-gate-check.sh "$(cg "$plain" "cd \\\"$repo\\\" && git commit -m x")"
check "subshell cd honoured"                  0 commit-gate-check.sh "$(cg "$repo"  "(cd $plain && git commit -m x)")"
check "last cd before the commit wins"        2 commit-gate-check.sh "$(cg "$plain" "cd $plain && cd $repo && git commit -m x")"
check "cd after the commit is ignored"        2 commit-gate-check.sh "$(cg "$repo"  "git commit -m x && cd $plain")"
check "cd inside a message is not a cd"       0 commit-gate-check.sh "$(cg "$plain" "git commit -m 'cd $repo now'")"
check "no cd -> payload cwd (gated)"          2 commit-gate-check.sh "$(cg "$repo"  "git commit -m x")"
check "no cd -> payload cwd (non-gated)"      0 commit-gate-check.sh "$(cg "$plain" "git commit -m x")"

# Fail safe: anything we cannot resolve without a shell falls back to the payload cwd.
check "missing cd target -> cwd (gated)"      2 commit-gate-check.sh "$(cg "$repo"  "cd $repo/nope && git commit -m x")"
check "missing cd target -> cwd (non-gated)"  0 commit-gate-check.sh "$(cg "$plain" "cd $plain/nope && git commit -m x")"
check "unexpanded variable -> cwd"            2 commit-gate-check.sh "$(cg "$repo"  "cd \$TARGET && git commit -m x")"

# ~ is expanded, against a throwaway HOME so the real one is never touched.
thome=$(mktemp -d)
(
    mkdir -p "$thome/gated" && cd "$thome/gated" || exit 1
    git init -q .
    git config user.email t@t.t; git config user.name t
    echo x > README.md; git add README.md; git commit -qm init
    mkdir -p .claude/.commit-gate src; echo "const d = 4;" > src/d.ts; git add src/d.ts
) >/dev/null 2>&1
HOME=$thome check "tilde cd path expanded"    2 commit-gate-check.sh "$(cg "$plain" "cd ~/gated && git commit -m x")"

# The target is parsed, never executed: a command substitution must not run.
sentinel="$plain/EXECUTED"
check "command substitution -> cwd"           2 commit-gate-check.sh "$(cg "$repo" "cd \$(touch $sentinel; echo $plain) && git commit -m x")"
if [ -e "$sentinel" ]; then
    fail=$((fail + 1)); echo "  FAIL: the cd target was executed to resolve it"
else
    pass=$((pass + 1)); echo "  ok: the cd target is never executed"
fi

# `git -C <path> … commit` relocates the commit exactly like a cd, so it is the same
# false-pass hole. git applies each -C in turn, left to right, relative to the previous —
# and only before the subcommand: `git commit -C <ref>` is --reuse-message, not a path.
check "git -C to a non-gated repo -> allowed" 0 commit-gate-check.sh "$(cg "$repo"  "git -C $plain commit -m x")"
check "git -C to the gated repo -> blocked"   2 commit-gate-check.sh "$(cg "$plain" "git -C $repo commit -m x")"
check "quoted -C path honoured"               2 commit-gate-check.sh "$(cg "$plain" "git -C \\\"$repo\\\" commit -m x")"
check "-C is relative to the cd in effect"    2 commit-gate-check.sh "$(cg "$plain" "cd $thome && git -C gated commit -m x")"
check "-C options are cumulative"             2 commit-gate-check.sh "$(cg "$plain" "git -C $thome -C gated commit -m x")"
check "missing -C target keeps the dir"       2 commit-gate-check.sh "$(cg "$plain" "cd $repo && git -C nope commit -m x")"
check "unresolvable -C keeps the dir"         2 commit-gate-check.sh "$(cg "$plain" "cd $repo && git -C \$T commit -m x")"
check "-C after the subcommand is a ref"      2 commit-gate-check.sh "$(cg "$repo"  "git commit -C $plain -m x")"
check "-C inside a message is not a flag"     0 commit-gate-check.sh "$(cg "$plain" "git commit -m 'reuse -C $repo here'")"

rm -rf "$repo" "$repo2" "$plain" "$thome" "$RUN_TRACKED_DIR"

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
echo "== compact-gate-check.sh =="
# PreCompact contract: exit 0 = the compaction proceeds, 2 = it is deferred with the reason
# on stderr. Same opt-in shape as the other gates, keyed on .claude/.compact-gate/.
cgt=$(mktemp -d)
CGATE="$cgt/.claude/.compact-gate"

pc() { # pc <trigger> <session-id> -> PreCompact payload
    printf '{"session_id":"%s","trigger":"%s","cwd":"%s"}' "$2" "$1" "$cgt"
}

check "manual compaction is never gated"      0 compact-gate-check.sh "$(pc manual s1)"
check "auto, no opt-in dir -> allowed"        0 compact-gate-check.sh "$(pc auto s1)"

mkdir -p "$CGATE"
check "opt-in, no checkpoint -> blocked"      2 compact-gate-check.sh "$(pc auto s1)"

# Freshness is mtime(checkpoint) > consumed_at, so the fixture is stamped explicitly into the
# future: writing it and re-running the hook can otherwise land in the same clock second, which
# ties rather than wins.
mkdir -p "$CGATE/sessions"
printf 'phase: implement\nnext: run the tests\n' > "$CGATE/sessions/s1.md"
touch -d '+1 hour' "$CGATE/sessions/s1.md"
check "fresh checkpoint -> allowed"           0 compact-gate-check.sh "$(pc auto s1)"
check "same checkpoint again -> blocked"      2 compact-gate-check.sh "$(pc auto s1)"
touch -d '+2 hours' "$CGATE/sessions/s1.md"
check "rewritten checkpoint -> allowed"       0 compact-gate-check.sh "$(pc auto s1)"

# Consuming a checkpoint must not remove it — compact-resume.sh replays the same file after
# the gate has passed on it.
if [ -f "$CGATE/sessions/s1.md" ]; then
    pass=$((pass + 1)); echo "  ok: the consumed checkpoint is left on disk"
else
    fail=$((fail + 1)); echo "  FAIL: the gate deleted the checkpoint it consumed"
fi

check_env "kill switch -> allowed"            0 compact-gate-check.sh "$(pc auto s2)" WORKFLOW_COMPACT_GATE=off

# The session id is interpolated into a path, so a traversing one must be rejected before any
# mkdir or stat runs — not merely fail to match an existing file.
before=$(find "$cgt" | sort)
check "traversing session id -> allowed"      0 compact-gate-check.sh "$(pc auto '../../escape')"
if [ "$(find "$cgt" | sort)" = "$before" ]; then
    pass=$((pass + 1)); echo "  ok: a traversing session id creates nothing"
else
    fail=$((fail + 1)); echo "  FAIL: a traversing session id wrote outside the gate directory"
fi

check "empty session id -> allowed"           0 compact-gate-check.sh "$(pc auto '')"
check "missing session id -> allowed"         0 compact-gate-check.sh "{\"trigger\":\"auto\",\"cwd\":\"$cgt\"}"

# Release valve: deferring for ever is worse than compacting without a checkpoint, so the gate
# gives up after MAX_BLOCKS consecutive blocks — and resets its counter when it does.
check_env "1st block under a valve of 1"      2 compact-gate-check.sh "$(pc auto s3)" WORKFLOW_COMPACT_GATE_MAX_BLOCKS=1
check_env "2nd attempt releases the valve"    0 compact-gate-check.sh "$(pc auto s3)" WORKFLOW_COMPACT_GATE_MAX_BLOCKS=1
check_env "counter reset -> blocks again"     2 compact-gate-check.sh "$(pc auto s3)" WORKFLOW_COMPACT_GATE_MAX_BLOCKS=1

# Token ceiling — the primary release valve. The PreCompact payload carries no token count,
# so the live context size is read from the tail of the transcript: the last assistant turn's
# usage, input + cache_read + cache_creation.
tx="$cgt/transcript.jsonl"
usage() { # usage <input> <cache-read> <cache-creation> -> one assistant transcript line
    printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' "$1" "$2" "$3"
}
pct() { # pct <session-id> <transcript-path> -> PreCompact payload carrying a transcript
    printf '{"session_id":"%s","trigger":"auto","cwd":"%s","transcript_path":"%s"}' "$1" "$cgt" "$2"
}

{ printf '{"type":"user","message":{"content":"hi"}}\n'; usage 2 100 50; usage 2 900 200; } > "$tx"
check_env "context over the ceiling -> allowed"   0 compact-gate-check.sh "$(pct t1 "$tx")" WORKFLOW_COMPACT_GATE_MAX_TOKENS=1000
check_env "context under the ceiling -> blocked"  2 compact-gate-check.sh "$(pct t2 "$tx")" WORKFLOW_COMPACT_GATE_MAX_TOKENS=100000
check_env "ceiling of 0 disables the valve"       2 compact-gate-check.sh "$(pct t3 "$tx")" WORKFLOW_COMPACT_GATE_MAX_TOKENS=0

# The LAST usage is the live size; an earlier, larger one is a compacted-away past. Reading the
# max — or the first — would release a session that has just been compacted back down.
{ usage 2 900 200; usage 2 100 50; } > "$cgt/shrunk.jsonl"
check_env "an earlier larger usage is ignored"    2 compact-gate-check.sh "$(pct t4 "$cgt/shrunk.jsonl")" WORKFLOW_COMPACT_GATE_MAX_TOKENS=1000

# An unreadable or unparseable transcript leaves the size unknown, which must fall through to
# the counter valves and block — never release, and never crash.
check_env "missing transcript -> blocked"         2 compact-gate-check.sh "$(pct t5 "$cgt/nope.jsonl")" WORKFLOW_COMPACT_GATE_MAX_TOKENS=1
printf 'not json at all\n{"type":"assistant","message":\n' > "$cgt/bad.jsonl"
check_env "malformed transcript -> blocked"       2 compact-gate-check.sh "$(pct t6 "$cgt/bad.jsonl")" WORKFLOW_COMPACT_GATE_MAX_TOKENS=1

# A readable size under the ceiling outranks the counter valves. They are proxies for "the
# context is getting dangerous"; letting a proxy overrule the direct measurement would release
# a few blocks past the trigger point every time, leaving the ceiling permanently unreachable.
check_env "readable size, 1st block"              2 compact-gate-check.sh "$(pct t7 "$tx")" WORKFLOW_COMPACT_GATE_MAX_BLOCKS=1 WORKFLOW_COMPACT_GATE_MAX_TOKENS=100000
check_env "block count cannot beat the ceiling"   2 compact-gate-check.sh "$(pct t7 "$tx")" WORKFLOW_COMPACT_GATE_MAX_BLOCKS=1 WORKFLOW_COMPACT_GATE_MAX_TOKENS=100000
check_env "elapsed time cannot beat it either"    2 compact-gate-check.sh "$(pct t7 "$tx")" WORKFLOW_COMPACT_GATE_MAX_DEFER_MIN=0 WORKFLOW_COMPACT_GATE_MAX_TOKENS=100000
# ... but with the size unreadable, the same counters must still release.
check_env "unreadable size, counter still fires"  0 compact-gate-check.sh "$(pct t7 "$cgt/nope.jsonl")" WORKFLOW_COMPACT_GATE_MAX_BLOCKS=1 WORKFLOW_COMPACT_GATE_MAX_TOKENS=100000

echo
echo "== compact-resume.sh =="
# SessionStart contract: always exit 0, stdout is injected into the session context.
rsm=$(mktemp -d)
resume() { # resume <session-id> <source> -> SessionStart payload
    printf '{"session_id":"%s","source":"%s","cwd":"%s"}' "$1" "$2" "$rsm"
}

check "not armed -> exits 0"                  0 compact-resume.sh "$(resume s1 startup)"
if [ -z "$(resume s1 startup | "$HOOKS/compact-resume.sh" 2>/dev/null)" ]; then
    pass=$((pass + 1)); echo "  ok: not armed -> prints nothing"
else
    fail=$((fail + 1)); echo "  FAIL: printed context in a repo that never opted in"
fi

mkdir -p "$rsm/.claude/.compact-gate/sessions"
check "armed -> exits 0"                      0 compact-resume.sh "$(resume s1 startup)"
# The model cannot derive its own session id, so this line is the only way it learns which
# file the gate is waiting for.
if resume s1 startup | "$HOOKS/compact-resume.sh" 2>/dev/null | grep -qF "$rsm/.claude/.compact-gate/sessions/s1.md"; then
    pass=$((pass + 1)); echo "  ok: armed -> prints this session's checkpoint path"
else
    fail=$((fail + 1)); echo "  FAIL: armed but the checkpoint path was not printed"
fi

printf 'phase: implement\nnext: run the tests\n' > "$rsm/.claude/.compact-gate/sessions/s1.md"
if resume s1 compact | "$HOOKS/compact-resume.sh" 2>/dev/null | grep -qF 'next: run the tests'; then
    pass=$((pass + 1)); echo "  ok: source=compact replays the checkpoint body"
else
    fail=$((fail + 1)); echo "  FAIL: source=compact did not replay the checkpoint"
fi

rm -rf "$cgt" "$rsm"

echo
echo "hooks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
