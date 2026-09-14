#!/usr/bin/env bash
# PostToolUse notice: tell the model when the session's resident context has grown past the
# point where every further turn is expensive, so it checkpoints and clears on a task
# boundary instead of riding one context to the window limit.
#
# Why this exists: cache-read is ~97% of input tokens, and it is re-billed in full on every
# request. Cost is therefore `context size x request count`, and the second factor is the one
# a long session multiplies. Measured over 22 sessions of one project: 40% of requests ran
# above 200k context and burned 64% of the budget; a single 788-request session reaching 480k
# was 42% of all main-thread spend. The same tool call at 400k costs ~3x what it costs at 130k.
#
# This hook only ever REPORTS — it never blocks. Deciding to clear is the user's call, and a
# hook that vetoed tool calls on context size would strand work mid-edit.
#
# It is also deliberately near-silent: it speaks at most once per threshold per session
# (state under ${TMPDIR:-/tmp}/claude-ctx-warn/), because a notice re-emitted on every tool
# call would itself become the context bloat it is warning about.
#
# Tuning: WORKFLOW_CTX_WARN (default 150000), WORKFLOW_CTX_ALERT (default 250000),
# WORKFLOW_CTX_WARN=off to disable entirely.
#
# Fails open everywhere: missing tool, unreadable transcript, unparseable payload -> exit 0
# silently. A missed warning is a rounding error; a hook that errors on every tool call is not.
set -u
[ "${WORKFLOW_CTX_WARN:-}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

WARN=${WORKFLOW_CTX_WARN:-150000}
ALERT=${WORKFLOW_CTX_ALERT:-250000}
case "$WARN" in ''|*[!0-9]*) WARN=150000 ;; esac
case "$ALERT" in ''|*[!0-9]*) ALERT=250000 ;; esac

input=$(cat)
session=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
transcript=$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)
# The id is interpolated into a path — reject anything outside this class before it reaches
# the filesystem.
case "$session" in
    ''|*[!A-Za-z0-9_-]*) exit 0 ;;
esac
[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0

# The live context size is the last assistant turn's usage. Read only the tail: slurping a
# long session's transcript would cost more than the warning saves, and a stale reading would
# fire the notice early.
total=$(tail -n 200 "$transcript" 2>/dev/null | jq -rRs '
    [ split("\n")[]
      | select(length > 0)
      | (fromjson? // empty)
      | select(.type? == "assistant")
      | (.message?.usage? // empty)
      | select(type == "object")
      | (.input_tokens? // 0)
        + (.cache_read_input_tokens? // 0)
        + (.cache_creation_input_tokens? // 0)
    ] | last // empty' 2>/dev/null)
case "$total" in ''|*[!0-9]*) exit 0 ;; esac

level=0
[ "$total" -ge "$WARN" ] && level=1
[ "$total" -ge "$ALERT" ] && level=2
[ "$level" -eq 0 ] && exit 0

state_dir="${TMPDIR:-/tmp}/claude-ctx-warn"
state_file="$state_dir/$session"
mkdir -p "$state_dir" 2>/dev/null || exit 0
said=$(cat "$state_file" 2>/dev/null)
case "$said" in ''|*[!0-9]*) said=0 ;; esac
# Already spoken at this level or higher — stay quiet.
[ "$level" -le "$said" ] && exit 0
printf '%s' "$level" > "$state_file" 2>/dev/null || true

if [ "$level" -ge 2 ]; then
    msg="Context is now ${total} tokens, past the ${ALERT} alert line. Every further turn in this session re-reads all ${total}. Finish or checkpoint the current task, then start a fresh session — carrying this context into unrelated work is the single most expensive habit available."
else
    msg="Context is now ${total} tokens, past the ${WARN} notice line. Each further turn re-reads all ${total}, so prefer writing findings to a file over keeping them in context, and treat the next task boundary as a /clear boundary."
fi

jq -cn --arg m "$msg" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$m}}' 2>/dev/null || true
exit 0
