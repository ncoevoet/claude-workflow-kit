#!/usr/bin/env bash
# tests/check-prove.sh — behavioural tests for tools/prove.sh: a mutation the
# check catches, one it misses, and a baseline that was already broken —
# asserting the exit code, and (where the file may have been touched) that the
# fixture ends up byte-identical to its original content with no
# target.txt.prove-bak left behind.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PROVE="$ROOT/tools/prove.sh"

pass=0; fail=0

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

target="$fixture/target.txt"
orig="$fixture/target.txt.orig"
checksh="$fixture/check.sh"

printf 'result = a + b\n# unrelated comment line\n' > "$target"
cp "$target" "$orig"

{
    echo '#!/usr/bin/env bash'
    echo "grep -qF 'a + b' target.txt"
} > "$checksh"
chmod +x "$checksh"

# case_check <name> <want-exit> <check-identity:0|1> -- <prove.sh args...>
case_check() {
    local name="$1" want="$2" check_identity="$3"; shift 3
    local got ok=1
    ( cd "$fixture" && "$PROVE" "$@" ) >/dev/null 2>&1
    got=$?
    [ "$got" = "$want" ] || ok=0
    if [ "$check_identity" -eq 1 ]; then
        cmp -s "$target" "$orig" || ok=0
        [ -e "$target.prove-bak" ] && ok=0
    fi
    if [ "$ok" -eq 1 ]; then
        pass=$((pass + 1)); echo "  PASS: $name"
    else
        fail=$((fail + 1)); echo "  FAIL: $name (want exit $want, got $got)"
    fi
}

echo "check-prove: tools/prove.sh behavioural tests"

case_check "caught: mutation is detected"   0 1 \
    --check ./check.sh --file target.txt --find "a + b" --replace "a - b" --cwd "$fixture"
case_check "not caught: mutation is missed" 1 1 \
    --check ./check.sh --file target.txt --find "unrelated comment line" --replace "something else entirely" --cwd "$fixture"
case_check "baseline already broken"        2 0 \
    --check false --file target.txt --find "a + b" --replace "a - b" --cwd "$fixture"

echo
echo "check-prove: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
