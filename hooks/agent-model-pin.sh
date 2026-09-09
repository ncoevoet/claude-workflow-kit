#!/usr/bin/env bash
# PreToolUse gate for Agent/Task spawns: require an explicit model.
# Roles: fable = Orchestrator, haiku = Scout, sonnet = Researcher, sonnet = Builder, opus = Refuter, opus = Debugger.
input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
model=$(jq -r '.tool_input.model // empty' <<<"$input" 2>/dev/null)
subtype=$(jq -r '.tool_input.subagent_type // empty' <<<"$input" 2>/dev/null)
[ "$subtype" = "fork" ] && exit 0
ROLES='  haiku  = Scout      (locate: files, symbols, call sites)
  sonnet = Researcher (read docs/source, report facts)
  sonnet = Builder    (code from a spec, run tests)
  opus   = Refuter    (review diff, rerun tests)
  opus   = Debugger   (root-cause only)'
case "$model" in
    haiku|sonnet|opus)
        exit 0
        ;;
    fable)
        echo "BLOCKED: fable is the orchestrator's model — never a subagent's.
Pin one by role:
$ROLES" >&2
        exit 2
        ;;
    "")
        echo "BLOCKED: subagent spawn without an explicit model.
Pin one by role:
$ROLES
fable is the orchestrator's model — never a subagent's." >&2
        exit 2
        ;;
    *)
        echo "BLOCKED: '$model' is not a valid subagent model.
Pin one by role:
$ROLES" >&2
        exit 2
        ;;
esac
