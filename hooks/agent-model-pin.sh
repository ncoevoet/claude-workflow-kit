#!/usr/bin/env bash
# PreToolUse gate for Agent/Task spawns: require an explicit model.
# Tiers: haiku = read-only mechanical, sonnet = mechanical with edits, opus = judgment.
input=$(cat)
model=$(jq -r '.tool_input.model // empty' <<<"$input" 2>/dev/null)
subtype=$(jq -r '.tool_input.subagent_type // empty' <<<"$input" 2>/dev/null)
[ "$subtype" = "fork" ] && exit 0
[ -n "$model" ] && exit 0
echo "BLOCKED: subagent spawn without an explicit model. Pin one — haiku (read-only mechanical: searches, enumeration, log mining), sonnet (mechanical with edits: tests, migrations, formatting), opus (judgment: design, root-cause, security, review verification). Forks are exempt (they inherit the parent model)." >&2
exit 2
