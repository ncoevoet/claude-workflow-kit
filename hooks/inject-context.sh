#!/usr/bin/env bash
# SessionStart hook: stdout is added to the session context.
# Injects the workflow's two always-on documents at every session start.
KIT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cat "$KIT/context/verification-standards.md" "$KIT/context/groundwork.md" 2>/dev/null
exit 0
