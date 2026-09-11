#!/usr/bin/env bash
# check-context-budget.sh — the injected payload must actually reach the model.
#
# Claude Code writes a hook's stdout to a file and injects a 2 KB preview in its place once the
# output passes roughly 10 KB. Measured on 2.1.268 by emitting a sentinel-terminated payload from
# a throwaway SessionStart hook and grepping the transcript: 10001 B arrives inline, 10100 B is
# replaced by `<persisted-output> … Preview (first 2KB)`. The same cap applies to the
# `hookSpecificOutput.additionalContext` JSON form, so there is no way to route around it.
#
# The limit is per hook result, which is why hooks.json injects one document per hook. This test
# measures what each hook actually emits — not what the file weighs — because the hook expands the
# @@KIT@@ placeholder, and an expansion is exactly the kind of growth a file-size check misses.
#
# Exit 0 = every chunk is deliverable and the README's stated cost is current.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
README="$ROOT/README.md"
HOOK="$ROOT/hooks/inject-context.sh"

# Measured boundary is between 10001 and 10100 bytes; this leaves room for a paragraph without
# leaving room for a second document.
CEILING=9500

rc=0
fail() { echo "  FAIL: $1" >&2; rc=1; }
ok()   { echo "  ok: $1"; }

echo "check-context-budget: SessionStart payload"

# Derived from hooks.json, not from a context/*.md glob: a document nobody injects must not be
# able to hide inside the byte total, and a document nobody counted must not be able to ship.
mapfile -t docs < <(python3 - "$ROOT/hooks/hooks.json" <<'PY'
import json, sys
for entries in json.load(open(sys.argv[1])).get("hooks", {}).get("SessionStart", []):
    for hook in entries.get("hooks", []):
        parts = hook.get("command", "").split()
        if len(parts) == 2 and parts[0].endswith("inject-context.sh"):
            print(parts[1])
PY
)

if [ "${#docs[@]}" -eq 0 ]; then
    fail "hooks.json injects no documents via inject-context.sh — 0 chunks measured"
    exit "$rc"
fi

total=0
for doc in "${docs[@]}"; do
    out=$(CLAUDE_PLUGIN_ROOT="$ROOT" "$HOOK" "$doc")
    n=$(printf '%s\n' "$out" | wc -c)
    total=$((total + n))
    if [ "$n" -le "$CEILING" ]; then
        ok "chunk $doc: $n B (ceiling $CEILING)"
    else
        fail "chunk $doc: $n B exceeds the $CEILING B ceiling — it would reach the model as a 2 KB preview"
    fi
    case "$out" in
        *@@KIT@@*) fail "chunk $doc still contains the unexpanded @@KIT@@ placeholder" ;;
    esac
done
echo "  ${#docs[@]} chunks measured, $total B injected per session"

grep -qF "$total" "$README" \
    && ok "README states the current per-session byte total ($total)" \
    || fail "README does not state the current per-session byte total ($total)"

# On-demand reference files earn their split only if the core documents actually point at them,
# and only if every path they point at resolves.
cited=0
for doc in "${docs[@]}"; do
    while IFS= read -r ref; do
        cited=$((cited + 1))
        [ -f "$ROOT/$ref" ] || fail "context/$doc.md cites $ref which does not exist"
    done < <(grep -oE 'context/reference/[A-Za-z0-9_.-]+\.md' "$ROOT/context/$doc.md")
done
for f in "$ROOT"/context/reference/*.md; do
    [ -e "$f" ] || continue
    rel="context/reference/$(basename "$f")"
    grep -qF "$rel" "$ROOT"/context/*.md \
        || fail "$rel ships but no injected document points at it — it would never be read"
done
[ "$cited" -gt 0 ] \
    && ok "$cited reference citations resolve, every reference file is cited" \
    || fail "no reference files are cited by any injected document"

exit "$rc"
