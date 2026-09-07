#!/usr/bin/env bash
# PreCompact gate for automatic compaction: refuse it until the model has written a
# checkpoint, so compaction lands on a task boundary with durable state on disk
# instead of mid-edit.
#
# OPT-IN PER REPOSITORY: exits 0 unless `.claude/.compact-gate/` exists at or above
# the session's cwd, so installing this plugin never defers a compaction in repos that
# do not use the gate:
#   mkdir -p .claude/.compact-gate
#
# State under <root>/.claude/.compact-gate/: sessions/<session_id>.md is the checkpoint
# the model writes; state/<session_id> is hook-owned key=value bookkeeping.
#
# Escapes: WORKFLOW_COMPACT_GATE=off disables it, and three release valves give up on the
# checkpoint rather than defer for ever. The PRIMARY one is the token ceiling
# WORKFLOW_COMPACT_GATE_MAX_TOKENS (default 350000), measured from the transcript, because
# it is the only valve tied to the thing that actually runs out. The block count
# (WORKFLOW_COMPACT_GATE_MAX_BLOCKS, default 8) and the elapsed time
# (WORKFLOW_COMPACT_GATE_MAX_DEFER_MIN, default 20) apply ONLY when the transcript cannot be
# read: no path, unreadable file, or unparseable JSON. While the size is readable the ceiling
# alone decides, or a low block count would release long before the ceiling is ever reached.
#
# The stderr below is HUMAN-facing only — measured: a PreCompact hook's stderr never reaches
# the model, and neither does hookSpecificOutput.additionalContext. The model learns where to
# write its checkpoint from compact-resume.sh, which runs at SessionStart and IS injected.
#
# Fails open everywhere: a missing tool, an unparseable payload, a missing field or any
# unexpected state exits 0. A compaction blocked by accident is far worse than one let through.
set -u
[ "${WORKFLOW_COMPACT_GATE:-}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

MAX_BLOCKS=${WORKFLOW_COMPACT_GATE_MAX_BLOCKS:-8}
MAX_DEFER_MIN=${WORKFLOW_COMPACT_GATE_MAX_DEFER_MIN:-20}
MAX_TOKENS=${WORKFLOW_COMPACT_GATE_MAX_TOKENS:-350000}
case "$MAX_BLOCKS" in ''|*[!0-9]*) MAX_BLOCKS=8 ;; esac
case "$MAX_DEFER_MIN" in ''|*[!0-9]*) MAX_DEFER_MIN=20 ;; esac
# 0 or garbage disables the token valve and leaves the counter valves in charge.
case "$MAX_TOKENS" in ''|*[!0-9]*) MAX_TOKENS=0 ;; esac

input=$(cat)
trigger=$(jq -r '.trigger // empty' <<<"$input" 2>/dev/null)
# Never block a human who typed /compact: the gate exists to stop the harness compacting
# mid-edit, not to argue with an explicit request.
[ "$trigger" = "auto" ] || exit 0

session=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
# The id is interpolated into a path, so anything outside this character class must never
# reach the filesystem — reject it before any mkdir or stat runs.
case "$session" in
    ''|*[!A-Za-z0-9_-]*) exit 0 ;;
esac

cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
transcript=$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)
start="${cwd:-${CLAUDE_PROJECT_DIR:-}}"
[ -n "$start" ] || exit 0
start=$(readlink -m "$start" 2>/dev/null) || exit 0

# Locate the directory that owns .claude/.compact-gate.
root=""
d="$start"
while :; do
    if [ -d "$d/.claude/.compact-gate" ]; then root="$d"; break; fi
    [ "$d" = "/" ] && break
    d=$(dirname "$d")
done
# Not enabled here — stay out of the way.
[ -n "$root" ] || exit 0

gate_dir="$root/.claude/.compact-gate"
checkpoint="$gate_dir/sessions/$session.md"
state_file="$gate_dir/state/$session"
mkdir -p "$gate_dir/sessions" "$gate_dir/state" 2>/dev/null || true

# --- state ----------------------------------------------------------------------------
# key=value lines; an absent or corrupt file reads as a session that has never been gated.
read_key() { awk -F= -v k="$1" '$1==k{print $2}' "$state_file" 2>/dev/null | tail -1; }
consumed_at=$(read_key consumed_at)
blocks=$(read_key blocks)
first_block=$(read_key first_block)
case "$consumed_at" in ''|*[!0-9]*) consumed_at=0 ;; esac
case "$blocks" in ''|*[!0-9]*) blocks=0 ;; esac
case "$first_block" in ''|*[!0-9]*) first_block=0 ;; esac

# write_state <consumed_at> <blocks> <first_block> — a failed write must never become a block.
write_state() {
    { printf 'consumed_at=%s\n' "$1"
      printf 'blocks=%s\n' "$2"
      printf 'first_block=%s\n' "$3"; } > "$state_file" 2>/dev/null || true
}

now=$(date +%s)

# --- fresh checkpoint -------------------------------------------------------------------
# Freshness is an mtime comparison, not a deletion: compact-resume.sh has to read this same
# file after the gate consumed it, to replay it into the post-compaction context.
mtime=$(stat -c %Y "$checkpoint" 2>/dev/null || echo 0)
case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
if [ "$mtime" -gt "$consumed_at" ]; then
    write_state "$mtime" 0 ""
    exit 0
fi

# --- release valve 1: token ceiling (primary) --------------------------------------------
# Deferring for ever is worse than compacting without a checkpoint: the context window is a
# hard limit, the checkpoint is only an optimisation. The PreCompact payload carries no token
# count, but the transcript does — the last assistant turn's usage is the live context size.
# Read only the tail: a long session's transcript is far too big to slurp, and a stale reading
# would release early. Anything unreadable or unparseable leaves the total unknown, which
# falls through to the counter valves below rather than releasing or blocking on its own.
total=""
if [ "$MAX_TOKENS" -gt 0 ] && [ -n "$transcript" ] && [ -r "$transcript" ]; then
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
    case "$total" in ''|*[!0-9]*) total="" ;; esac
fi
if [ -n "$total" ] && [ "$total" -ge "$MAX_TOKENS" ]; then
    write_state "$now" 0 ""
    echo "compact gate: context is $total tokens, at or over the $MAX_TOKENS ceiling — compacting now, without a checkpoint." >&2
    exit 0
fi

# --- release valves 2 and 3: block count and elapsed time (backstops) ---------------------
# ONLY when the token total is unknown. A known total under the ceiling must keep blocking:
# these two counters are proxies for "context is getting dangerous", and letting a proxy
# overrule the direct measurement would release around the trigger point every time, leaving
# the ceiling that the whole design is built on unreachable.
deferred_min=0
[ "$first_block" -gt 0 ] && deferred_min=$(( (now - first_block) / 60 ))
if [ -z "$total" ] && { [ "$blocks" -ge "$MAX_BLOCKS" ] || [ "$deferred_min" -ge "$MAX_DEFER_MIN" ]; }; then
    write_state "$now" 0 ""
    echo "compact gate: release valve tripped after $blocks block(s) / ${deferred_min}m — compacting without a checkpoint." >&2
    exit 0
fi

# --- block --------------------------------------------------------------------------------
[ "$first_block" -gt 0 ] || first_block=$now
write_state "$consumed_at" "$((blocks + 1))" "$first_block"
echo "compact gate: automatic compaction deferred, block $((blocks + 1)) of $MAX_BLOCKS — this session has no fresh checkpoint yet." >&2
echo "Waiting for $checkpoint${total:+ (context: $total tokens)}." >&2
echo "It releases at $MAX_TOKENS tokens${total:+ (the only valve that applies while the context size is readable)}, and — when the transcript cannot be read — after $MAX_BLOCKS blocks or ${MAX_DEFER_MIN}m; WORKFLOW_COMPACT_GATE=off turns it off." >&2
exit 2
