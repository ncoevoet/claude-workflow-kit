#!/usr/bin/env bash
# SessionStart hook: stdout is added to the session context — but only up to a point. Claude Code
# persists a hook's stdout to a file and injects a 2 KB preview in its place once the output
# exceeds roughly 10 KB (measured on 2.1.268: 10001 B lands inline, 10100 B is persisted; the
# `hookSpecificOutput.additionalContext` JSON form is capped identically). A single cat of all
# three documents was 23533 B and therefore reached the model as a 2 KB preview — the rules were
# being paid for and not delivered.
#
# The limit applies per hook result, so hooks.json invokes this script once per document and each
# one stays well under it. The harness does not preserve the order of the results, which is why
# each document is self-contained and self-titled rather than a slice of one larger text.
#
# $1 = document basename under context/, without the .md extension.
KIT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
doc="$KIT/context/${1:-}.md"
[ -f "$doc" ] || exit 0

# On-demand reference files are cited by absolute path, resolved here: the model's cwd is the
# user's repository, not the plugin, so a relative path would not open.
kit_escaped=$(printf '%s' "$KIT" | sed -e 's/[&#\]/\\&/g')
sed "s#@@KIT@@#${kit_escaped}#g" "$doc"
exit 0
