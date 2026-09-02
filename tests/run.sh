#!/usr/bin/env bash
# Deterministic test suite — no network / API key. Safe for CI.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
rc=0

echo "== anonymization gate =="
bash "$HERE/check-anonymization.sh" || rc=1

echo
echo "== gate contract invariants =="
bash "$HERE/check-gate-contract.sh" || rc=1

echo
echo "== JSON manifests valid =="
for f in "$ROOT/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/marketplace.json" "$ROOT/hooks/hooks.json" "$ROOT/.mcp.json"; do
  if python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
    echo "  ok: ${f#"$ROOT"/}"
  else
    echo "  INVALID JSON: $f"; rc=1
  fi
done

echo
echo "== every hook referenced by hooks.json exists and is executable =="
while read -r h; do
  [ -n "$h" ] || continue
  p="$ROOT/${h#*/hooks/}"; p="$ROOT/hooks/$(basename "$h")"
  if [ -x "$p" ]; then echo "  ok: $(basename "$h")"; else echo "  MISSING/NOT EXECUTABLE: $p"; rc=1; fi
done < <(python3 - "$ROOT/hooks/hooks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for entries in d.get("hooks", {}).values():
    for entry in entries:
        for hook in entry.get("hooks", []):
            cmd = hook.get("command", "")
            if "/hooks/" in cmd:
                print(cmd.split("/hooks/")[-1].strip('"'))
PY
)

echo
echo "== skill frontmatter present =="
for f in "$ROOT"/skills/*/SKILL.md; do
  [ -e "$f" ] || continue
  if head -1 "$f" | grep -q '^---$' && grep -q '^name:' "$f" && grep -q '^description:' "$f"; then
    echo "  ok: ${f#"$ROOT"/}"
  else
    echo "  BAD FRONTMATTER: $f"; rc=1
  fi
done

echo
echo "== shell syntax (bash -n) =="
for f in "$ROOT"/hooks/*.sh "$ROOT"/tests/*.sh; do
  [ -e "$f" ] || continue
  if bash -n "$f"; then echo "  ok: ${f##*/}"; else echo "  SYNTAX ERROR: $f"; rc=1; fi
done

echo
echo "== shellcheck (if available) =="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$ROOT"/hooks/*.sh; then echo "  shellcheck clean"; else rc=1; fi
else
  echo "  shellcheck not installed — skipped (CI runs it)"
fi

echo
echo "== hook behaviour =="
if "$HERE/test_hooks.sh"; then :; else rc=1; fi

echo
if [ "$rc" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED"; fi
exit "$rc"
