#!/usr/bin/env bash
# PreToolUse gate for Agent/Task spawns: require an explicit model.
# Roles: fable = Orchestrator, haiku = Scout, sonnet = Researcher, sonnet = Builder, opus = Refuter, opus = Debugger.
#
# Rejecting `fable` is a DELIBERATE local policy, not a schema fix. Claude Code documents
# `fable` as a legal subagent `model` value (sub-agents.md lists sonnet, opus, haiku, fable, a
# full model ID, or `inherit`). This kit reserves it for the orchestrator, so a spawn naming it
# is a role error worth blocking. Do not "correct" this to match the docs.
#
# Note also what this hook CANNOT do: it checks the model string is present and in the set. It
# cannot tell whether the tier fits the role, and it has no view of `effort` at all — effort has
# no spawn-time parameter and is only settable in skill or subagent frontmatter.
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
