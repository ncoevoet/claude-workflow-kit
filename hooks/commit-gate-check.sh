#!/usr/bin/env bash
# PreToolUse Bash guard: block `git commit` unless the commit-gate-guard skill recorded a
# PASS for the exact staged diff.
#
# OPT-IN PER REPOSITORY: exits 0 unless `.claude/.commit-gate/` exists, so installing this
# plugin never blocks commits in repos that do not use the gate. Enable with:
#   mkdir -p .claude/.commit-gate
#
# The repository checked is the one the commit will RUN in (`cd /elsewhere && git commit`
# and `git -C /elsewhere commit` are both honoured), not the session cwd — see the
# resolution block below.
input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
[ -z "$cmd" ] && exit 0

# Only real commits. Ignore --dry-run, and ignore commands that merely mention the words.
case "$cmd" in
    *"git commit"*|*"git "*" commit"*) ;;
    *) exit 0 ;;
esac
case "$cmd" in *--dry-run*) exit 0 ;; esac

# --- which repository will this commit actually run in? -------------------------------
# The payload cwd is where the session's shell sits, which is not necessarily where the
# commit runs: `cd /other-repo && git commit …` and `git -C /other-repo commit …` both
# target a different repository. Gating the wrong one is wrong in both directions — it
# blocks a repo that never opted in, and (worse) it silently skips the gate for a repo
# that did. So walk the command for the directory in effect when the commit runs.
#
# PARSED, NEVER EXECUTED. Anything that would need a shell to resolve (variables, command
# substitution, globs, brace expansion, `cd -`) is unresolvable — and unresolvable never
# means "no gate": a wrong block is recoverable, a gate that silently does not run is not.

# first_word <string> — the leading shell word, surrounding quotes stripped.
first_word() {
    local s=${1#"${1%%[![:space:]]*}"}
    case "$s" in
        '"'*) s=${s#\"}; s=${s%%\"*} ;;
        "'"*) s=${s#\'}; s=${s%%\'*} ;;
        *)    s=${s%%[[:space:]]*} ;;
    esac
    printf '%s' "$s"
}

# resolve_dir <base> <token> — the directory <token> selects, relative to <base>; empty
# when it cannot be known without running a shell. Nothing here is expanded or executed.
resolve_dir() {
    case "$2" in
        ''|-|--)                             return ;;   # needs $HOME / $OLDPWD state
        *'$'*|*'`'*|*'*'*|*'?'*|*'['*|*'{'*) return ;;   # needs the shell to expand
        [~]|[~]/*)                           printf '%s' "$HOME${2#?}" ;;  # [~] = literal ~
        /*)                                  printf '%s' "$2" ;;
        *) if [ -n "$1" ]; then printf '%s' "$1/$2"; fi ;;   # relative to the base
    esac
}

run_dir="$cwd"
# Split on shell separators so a `cd` counts only when it starts its own segment — a `cd`
# inside a commit message or a quoted argument is text, not a directory change.
while IFS= read -r seg; do
    seg=${seg#"${seg%%[![:space:]({]*}"}            # drop leading blanks and ( { grouping
    case "$seg" in
        *"git commit"*|*"git "*" commit"*)
            # `git -C <path> … commit` moves the commit too, and git applies each -C in
            # turn, left to right, relative to the previous one. Only the options BEFORE
            # the subcommand are git's own: `git commit -C <ref>` is --reuse-message and
            # must never be read as a directory, so cut the segment at ` commit` first.
            # git itself only accepts `-C <path>` as two words, so that is all we match.
            rest=${seg%%[[:space:]]commit*}
            while :; do
                after=${rest#*[[:space:]]-C[[:space:]]}
                [ "$after" = "$rest" ] && break
                cdir=$(resolve_dir "$run_dir" "$(first_word "$after")")
                # Unresolvable or missing: keep the directory already in effect.
                if [ -n "$cdir" ] && [ -d "$cdir" ]; then run_dir="$cdir"; fi
                rest=$after
            done
            break ;;                                # the commit runs in run_dir
        cd|cd[[:space:]]*) ;;
        *) continue ;;
    esac
    # A `cd` we cannot read loses the shell's location entirely, so it clears run_dir and
    # the payload cwd becomes the anchor again — unlike a -C, which is one option on a
    # command whose directory we still know.
    run_dir=$(resolve_dir "$run_dir" "$(first_word "${seg#cd}")")
done <<<"$(printf '%s' "$cmd" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/[;|]/\n/g')"
if [ -n "$run_dir" ]; then
    run_dir=$(readlink -m "$run_dir" 2>/dev/null)
    # A path that does not exist is a parse we got wrong: fall back to the payload cwd.
    if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then cwd="$run_dir"; fi
fi

[ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

# Locate the directory that owns .claude/.commit-gate, walking up from the resolved repo.
gate_dir=""
d="$cwd"
for _ in 1 2 3 4 5 6; do
    if [ -d "$d/.claude/.commit-gate" ]; then gate_dir="$d/.claude/.commit-gate"; break; fi
    [ "$d" = "/" ] && break
    d=$(dirname "$d")
done
# Not enabled in this repo — stay out of the way.
[ -n "$gate_dir" ] || exit 0

# Docs-only staged diffs are not gated.
staged=$(git diff --cached --name-only 2>/dev/null)
[ -n "$staged" ] || exit 0
if ! grep -qvE '(\.md$|^\.claude/|/\.claude/)' <<<"$staged"; then exit 0; fi

# In-flight verification. A gate is only proof once it has exited, so a commit is refused
# while a tracked run is still alive. PID files are the opt-in: none present, nothing blocks.
#   - "$gate_dir/inflight/<kind>.pid"  — written by whatever launches your gates
#   - $RUN_TRACKED_DIR/run-tracked-<kind>.pid — the bg-watch skill's convention (default /tmp)
# Kinds starting with dev/serve are long-lived servers, not verification, and never block.
inflight=""
for pid_file in "$gate_dir"/inflight/*.pid "${RUN_TRACKED_DIR:-/tmp}"/run-tracked-*.pid; do
    [ -f "$pid_file" ] || continue
    kind=$(basename "$pid_file" .pid); kind="${kind#run-tracked-}"
    case "$kind" in dev*|serve*) continue ;; esac
    pid=$(tr -dc '0-9' < "$pid_file")
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null && inflight="$inflight
  $kind (pid $pid) — $pid_file"
done
if [ -n "$inflight" ]; then
    echo "Commit blocked — verification is still running:$inflight" >&2
    echo "A gate proves nothing until it exits: wait for the run and read its exit code. If the process is gone, the PID file is stale — delete it." >&2
    exit 2
fi

marker="$gate_dir/last-pass"
if [ ! -f "$marker" ]; then
    echo "Commit blocked — no commit-gate PASS recorded." >&2
    echo "Run the commit-gate-guard skill: it reviews everything changed since the last review, then writes $marker." >&2
    exit 2
fi

current=$(git diff --cached | sha256sum | cut -d' ' -f1)
recorded=$(tr -d '[:space:]' < "$marker")
if [ "$current" != "$recorded" ]; then
    echo "Commit blocked — the staged diff changed since the last commit-gate PASS." >&2
    echo "The gate fingerprints the exact staged bytes, so re-staging invalidates it. Re-run commit-gate-guard." >&2
    exit 2
fi
exit 0
