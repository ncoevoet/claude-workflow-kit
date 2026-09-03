#!/usr/bin/env bash
# check-gate-contract.sh — invariant gate over the prose contract.
#
# The plugin's product is instructions, so the failure mode is drift: the skill
# telling the model one marker path while the hook reads another, or the README
# advertising an opt-in step that no longer matches. Nothing in `bash -n` or the
# behavioural tests catches that — the hook and the skill are green in isolation
# and disagree with each other. These assertions pin the couplings.
#
# Exit 0 = consistent, 1 = drift found.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SKILL="$ROOT/skills/commit-gate-guard/SKILL.md"
HOOK="$ROOT/hooks/commit-gate-check.sh"
README="$ROOT/README.md"
STANDARDS="$ROOT/context/verification-standards.md"
BASH_HOOK="$ROOT/hooks/bash-guard.sh"
rc=0

fail() { echo "  FAIL: $1" >&2; rc=1; }
ok()   { echo "  ok: $1"; }

# in <label> <needle> <file...>
in_files() {
    local label="$1" needle="$2"; shift 2
    local f
    for f in "$@"; do
        grep -qF -- "$needle" "$f" || { fail "$label — '$needle' missing from ${f#"$ROOT"/}"; return; }
    done
    ok "$label"
}

echo "check-gate-contract: skill <-> hook <-> README"

# 1. Both marker files are named identically wherever they are described or read.
in_files "last-pass marker documented"    ".claude/.commit-gate/last-pass"   "$SKILL"
in_files "last-review marker documented"  ".claude/.commit-gate/last-review" "$SKILL"
# The hook composes the path from the resolved gate dir, so assert the basename it reads.
in_files "hook reads the last-pass marker" "last-pass" "$HOOK"

# 2. The opt-in directory is the same string in all three places.
in_files "opt-in dir agrees" ".claude/.commit-gate" "$SKILL" "$HOOK" "$README"

# 3. The hook must stay opt-in — a regression here blocks commits in every repo
#    that merely installs the plugin.
grep -q 'exits 0 unless' "$SKILL" || fail "skill no longer documents the opt-in behaviour"
grep -qF 'commit-gate' "$HOOK" && grep -q 'gate_dir' "$HOOK" \
    || fail "hook no longer resolves an opt-in gate directory"
[ "$rc" -eq 0 ] && ok "opt-in contract documented and implemented"

# 4. The delta must be scoped to the last review, not the staged diff — that is the
#    whole point of the gate and the easiest thing to quietly narrow.
grep -q 'last-review' "$SKILL" && grep -qiE 'since the last (recorded )?review' "$SKILL" \
    && ok "delta is scoped to the last recorded review" \
    || fail "skill no longer scopes the delta to the last recorded review"

# 5. A single bounded pass — if this becomes a fan-out it stops being cheap enough to run.
grep -qiE 'ONE .*agent|one bounded|single .*pass' "$SKILL" \
    && ok "review pass is documented as bounded" \
    || fail "skill no longer bounds the review to one pass"

# 6. Blocking severities are stated.
grep -qE 'CRITICAL' "$SKILL" && grep -qE 'IMPORTANT' "$SKILL" \
    && ok "blocking severities stated" \
    || fail "skill no longer states which severities block"

# 7. Every hook referenced by hooks.json exists, is executable, and is documented in the README.
# Extracted once so section 12 can check the reverse direction against the same list.
hooks_json_names=$(python3 - "$ROOT/hooks/hooks.json" <<'PY'
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
while read -r name; do
    [ -n "$name" ] || continue
    [ -x "$ROOT/hooks/$name" ] || fail "hooks.json references hooks/$name which is missing or not executable"
    grep -qF "hooks/$name" "$README" || fail "hooks/$name is not documented in README.md"
done <<<"$hooks_json_names"
[ "$rc" -eq 0 ] && ok "hooks.json entries exist and are documented"

# 8. README version badge matches plugin.json.
ver=$(python3 -c "import json;print(json.load(open('$ROOT/.claude-plugin/plugin.json'))['version'])")
grep -qF "version-$ver-blue" "$README" \
    && ok "README badge matches plugin.json version ($ver)" \
    || fail "README version badge does not match plugin.json ($ver)"
mver=$(python3 -c "import json;print(json.load(open('$ROOT/.claude-plugin/marketplace.json'))['plugins'][0]['version'])")
[ "$mver" = "$ver" ] \
    && ok "marketplace.json matches plugin.json version ($ver)" \
    || fail "marketplace.json says $mver, plugin.json says $ver"

# 9. The in-flight block is the gate's second half — the marker proves a review ran, this
#    proves the run it depended on finished. Both PID sources and the dev/serve carve-out
#    must be described wherever they are read, or the block silently changes meaning.
in_files "inflight dir documented"       ".claude/.commit-gate/inflight" "$SKILL" "$README"
in_files "bg-watch convention documented" "run-tracked-" "$SKILL" "$README"
pid_glob=$(grep -F 'for pid_file in' "$HOOK")
[ -n "$pid_glob" ] && grep -qF '/inflight/*.pid' <<<"$pid_glob" && grep -qF 'run-tracked-*.pid' <<<"$pid_glob" \
    && ok "hook globs both pid sources" \
    || fail "hook no longer globs both inflight pid sources"
grep -qE 'dev\*\|serve\*' "$HOOK" && grep -qiE 'dev.*serve.*never block|beginning `dev` or `serve`' "$SKILL" \
    && ok "dev/serve carve-out implemented and documented" \
    || fail "dev/serve carve-out drifted between hook and skill"

# 10. The wait guard only helps if its block message names the alternative the standards
#     prescribe. A guard that says "no" without saying "instead" just gets worked around.
in_files "waiting rule documented"  "run_in_background" "$STANDARDS" "$README"
wait_msg=$(grep -F 'BLOCKED: foreground wait' "$BASH_HOOK")
[ -n "$wait_msg" ] && grep -qF 'run_in_background' <<<"$wait_msg" && grep -qF 'Monitor' <<<"$wait_msg" \
    && ok "wait guard names both alternatives in its message" \
    || fail "wait guard message no longer names run_in_background and Monitor"
grep -qF 'bash-guard.sh' "$STANDARDS" \
    && ok "standards credit the enforcing hook" \
    || fail "standards no longer name bash-guard.sh as the enforcer"

echo
echo "11. spec gate <-> groundwork <-> README"
SPEC_HOOK="$ROOT/hooks/spec-gate-check.sh"
GROUNDWORK="$ROOT/context/groundwork.md"
COMMIT_HOOK="$ROOT/hooks/commit-gate-check.sh"

in_files "opt-in dir named everywhere"   '.claude/.spec-gate' "$SPEC_HOOK" "$README" "$GROUNDWORK"
in_files "spec path convention shared"   '.claude/specs/'     "$SPEC_HOOK" "$GROUNDWORK"
in_files "review heading shared"         '## Adversarial review' "$SPEC_HOOK" "$GROUNDWORK" "$README"

# The heading the hook actually matches, not just the literal in its message. If groundwork's
# skeleton and this awk pattern drift by one character every correct run is falsely blocked,
# and the behavioural tests stay green because they use their own fixtures.
grep -qF '[Aa]dversarial[[:space:]]+[Rr]eview' "$SPEC_HOOK" \
    && ok "hook matcher pattern present (not just the prose literal)" \
    || fail "spec-gate matcher pattern changed — re-pin it against groundwork's skeleton"

# Both gates must agree on what counts as code.
excl='(\.md$|^\.claude/|/\.claude/)'
if grep -qF -- "$excl" "$SPEC_HOOK" && grep -qF -- "$excl" "$COMMIT_HOOK"; then
    ok "both gates share the code/docs exclusion literal"
else
    fail "the two gates no longer share the exclusion literal"
fi

grep -qF 'exits 0 unless' "$SPEC_HOOK" \
    && ok "spec gate documents its opt-in" \
    || fail "spec-gate-check.sh no longer documents the opt-in"

# Every env var the hook reads must be documented, or users cannot find the escape.
for v in WORKFLOW_SPEC_GATE WORKFLOW_SPEC_GATE_FREE_FILES WORKFLOW_SPEC_GATE_WINDOW_MIN WORKFLOW_SPEC_GATE_TTL_MIN; do
    grep -qF "$v" "$README" || fail "env var $v is read by the hook but undocumented in README"
done
grep -qF 'WORKFLOW_SPEC_GATE=off' "$SPEC_HOOK" \
    && ok "block message names the kill switch" \
    || fail "spec-gate block message no longer names WORKFLOW_SPEC_GATE"

echo
echo "12. every hooks/*.sh file is wired into hooks.json"
# The reverse of section 7: that direction checks hooks.json -> filesystem (every
# reference resolves); this checks filesystem -> hooks.json (nothing ships unwired).
# Reuses the same $hooks_json_names extraction, not a second parser.
for f in "$ROOT"/hooks/*.sh; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    grep -qxF "$base" <<<"$hooks_json_names" \
        || fail "hooks/$base exists on disk but is not referenced by hooks.json"
done
[ "$rc" -eq 0 ] && ok "every hooks/*.sh file is wired into hooks.json"

exit "$rc"
