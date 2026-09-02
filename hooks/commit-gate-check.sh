#!/usr/bin/env bash
# PreToolUse Bash guard: block `git commit` unless the commit-gate-guard skill recorded a
# PASS for the exact staged diff.
#
# OPT-IN PER REPOSITORY: exits 0 unless `.claude/.commit-gate/` exists, so installing this
# plugin never blocks commits in repos that do not use the gate. Enable with:
#   mkdir -p .claude/.commit-gate
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

[ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

# Locate the directory that owns .claude/.commit-gate, walking up from cwd.
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
