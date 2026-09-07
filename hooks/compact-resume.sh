#!/usr/bin/env bash
# SessionStart hook: stdout is added to the session context. Companion to
# compact-gate-check.sh, gated by the same opt-in directory — exits 0 unless
# `.claude/.compact-gate/` exists at or above the session's cwd, and prints nothing then.
#
# Always: names the checkpoint file for THIS session. The model cannot derive its own
# session id, so without this line it can never write the file the gate is waiting for.
# After a compaction (source=compact, same session_id as before it): also replays the
# checkpoint and the cheap facts a fresh context lost — active spec, working tree, last commits.
#
# Exits 0 unconditionally: a SessionStart hook must never be able to fail a session start.
set -u
MAX_CHARS=4000

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
session=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
source_kind=$(jq -r '.source // empty' <<<"$input" 2>/dev/null)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)

# Same guard as the gate: the id is interpolated into a path.
case "$session" in
    ''|*[!A-Za-z0-9_-]*) exit 0 ;;
esac

start="${cwd:-${CLAUDE_PROJECT_DIR:-}}"
[ -n "$start" ] || exit 0
start=$(readlink -m "$start" 2>/dev/null) || exit 0

root=""
d="$start"
while :; do
    if [ -d "$d/.claude/.compact-gate" ]; then root="$d"; break; fi
    [ "$d" = "/" ] && break
    d=$(dirname "$d")
done
[ -n "$root" ] || exit 0

checkpoint="$root/.claude/.compact-gate/sessions/$session.md"
out="Compaction checkpoint for this session: $checkpoint"$'\n'
out+="Whenever a piece of work becomes durable, write that file — current phase, what is already durable, the exact next action, files in flight — then make one more small tool call, because the compact gate only runs on the next compaction attempt."$'\n'

if [ "$source_kind" = "compact" ]; then
    if [ -f "$checkpoint" ]; then
        out+=$'\n'"--- checkpoint ---"$'\n'"$(cat "$checkpoint" 2>/dev/null)"$'\n'
    fi
    pointer=$(head -1 "$root/.claude/.spec-gate/current" 2>/dev/null)
    [ -n "$pointer" ] && out+=$'\n'"Active spec: $pointer"$'\n'
    # Outside a repository these print nothing and fail silently.
    status=$(git -C "$root" status --short 2>/dev/null | head -40)
    [ -n "$status" ] && out+=$'\n'"--- git status --short ---"$'\n'"$status"$'\n'
    log=$(git -C "$root" log --oneline -3 2>/dev/null)
    [ -n "$log" ] && out+=$'\n'"--- git log --oneline -3 ---"$'\n'"$log"$'\n'
fi

# Hook output limits are documented loosely, so truncate here rather than risk the harness
# silently eating the tail of the resume payload.
[ "${#out}" -gt "$MAX_CHARS" ] && out="${out:0:$((MAX_CHARS - 13))}"$'\n[truncated]\n'
printf '%s' "$out"
exit 0
