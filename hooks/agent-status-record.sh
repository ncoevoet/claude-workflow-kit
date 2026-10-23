#!/usr/bin/env bash
# SubagentStop recorder: leave a durable "this agent stopped" fact on disk, so the orchestrator
# can answer "is agent X still running?" from a file instead of from memory.
# Writes <cwd>/.claude/.scratch/agents/<agent_id>.json:
#   {agent_id, agent_type, stopped_at (ISO UTC), last_message_tail (last 600 chars)}
# Input fields used (documented SubagentStop payload): cwd, agent_id, agent_type,
# last_assistant_message.
# Never blocks: always exits 0. Does nothing without jq or without an agent_id.
set -u
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')
[ -n "$id" ] || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd=$PWD
dir="$cwd/.claude/.scratch/agents"
mkdir -p "$dir" 2>/dev/null || exit 0
printf '%s' "$input" | jq --arg id "$id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
    agent_id: $id,
    agent_type: (.agent_type // ""),
    stopped_at: $at,
    last_message_tail: ((.last_assistant_message // "") | tostring | .[-600:])
}' > "$dir/$id.json" 2>/dev/null
exit 0
