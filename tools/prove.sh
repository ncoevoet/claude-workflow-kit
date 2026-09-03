#!/usr/bin/env bash
# tools/prove.sh — a check nobody has watched fail is unverified: this script
# breaks the file a check is supposed to catch, confirms the check goes red,
# restores the file, and confirms the check goes green again. See
# context/verification-standards.md — "make it fail on purpose" is the only way
# to know a check watches what you think it watches. Bash port of prove.cjs;
# zero non-stdlib deps (python3 does the literal find/replace).
set -u

TAIL_LINES=40

usage() {
    echo 'usage: tools/prove.sh --check "<shell command>" --file <path> --find "<literal string>" --replace "<literal string>" [--cwd <dir>]' >&2
    exit 2
}

check_cmd=""
file_arg=""
find_str=""
replace_str=""
cwd_arg=""
have_check=0
have_file=0
have_find=0
have_replace=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check|--file|--find|--replace|--cwd)
            key="$1"
            if [ $# -ge 2 ]; then val="$2"; shift 2; else val=""; shift 1; fi
            case "$key" in
                --check)   check_cmd="$val";   have_check=1 ;;
                --file)    file_arg="$val";    have_file=1 ;;
                --find)    find_str="$val";    have_find=1 ;;
                --replace) replace_str="$val"; have_replace=1 ;;
                --cwd)     cwd_arg="$val" ;;
            esac
            ;;
        *) usage ;;
    esac
done

if [ "$have_check" -ne 1 ] || [ "$have_file" -ne 1 ] || [ "$have_find" -ne 1 ] || [ "$have_replace" -ne 1 ]; then
    usage
fi

# --- state the INT/TERM trap needs to see, mirroring prove.cjs's emergencyRestore() ---
file_path=""
backup=""
mutated=0

# Only reachable via `trap ... INT/TERM` below — shellcheck's static
# reachability check cannot see that call.
# shellcheck disable=SC2317
emergency_restore() {
    if [ "$mutated" -eq 1 ] && [ -n "$backup" ] && [ -f "$backup" ]; then
        cp -p -- "$backup" "$file_path" 2>/dev/null
        mutated=0
    fi
    if [ -n "$backup" ] && [ -f "$backup" ]; then
        rm -f -- "$backup"
    fi
}

# shellcheck disable=SC2317
on_int()  { emergency_restore; exit 130; }
# shellcheck disable=SC2317
on_term() { emergency_restore; exit 143; }
trap on_int INT
trap on_term TERM

file_path=$(readlink -m "$file_arg" 2>/dev/null)
if [ -z "$file_path" ] || [ ! -f "$file_path" ]; then
    echo "SETUP FAILED: target file does not exist: $file_path" >&2
    exit 2
fi

if [ -n "$cwd_arg" ]; then
    cwd_path=$(readlink -m "$cwd_arg" 2>/dev/null)
else
    cwd_path=$(readlink -m "$(dirname "$file_path")" 2>/dev/null)
fi

log() {
    echo "[prove] $1"
}

tail_to_stderr() {
    tail -n "$TAIL_LINES" "$1" >&2
}

# run_check <outfile> — runs $check_cmd via eval in a subshell cd'd to $cwd_path,
# combined stdout+stderr captured to <outfile>. Sets check_status.
run_check() {
    ( set +u; cd "$cwd_path" 2>/dev/null || exit 127; eval "$check_cmd" ) >"$1" 2>&1
    check_status=$?
}

# --- a. baseline ---
baseline_out=$(mktemp)
run_check "$baseline_out"
if [ "$check_status" -ne 0 ]; then
    echo "BASELINE FAILED: fix the check before proving it" >&2
    tail_to_stderr "$baseline_out"
    rm -f "$baseline_out"
    exit 2
fi
rm -f "$baseline_out"
log "baseline ok"

# --- b. backup, then assert --find is actually present ---
backup="${file_path}.prove-bak"
cp -p -- "$file_path" "$backup"

if ! grep -qF -- "$find_str" "$file_path"; then
    echo "SETUP FAILED: --find string was not found in $file_path; file left untouched" >&2
    rm -f -- "$backup"
    exit 2
fi

# --- c. mutate: literal replace-all, never a bash glob/regex substitution ---
python3 - "$file_path" "$find_str" "$replace_str" <<'PY'
import sys
path = sys.argv[1]
find = sys.argv[2].encode()
repl = sys.argv[3].encode()
with open(path, "rb") as f:
    data = f.read()
with open(path, "wb") as f:
    f.write(data.replace(find, repl))
PY
mutated=1
log "mutation applied"

# --- d. run check again, expect it to go red ---
mutation_out=$(mktemp)
run_check "$mutation_out"
mutation_status=$check_status
rm -f "$mutation_out"
if [ "$mutation_status" -ne 0 ]; then
    log "check went red"
else
    log "check stayed green"
fi

# --- e. always restore ---
cp -p -- "$backup" "$file_path"
mutated=0
rm -f -- "$backup"
log "restored"

restore_out=$(mktemp)
run_check "$restore_out"
restore_status=$check_status
if [ "$restore_status" -ne 0 ]; then
    echo "RESTORE FAILED: the restore-side rerun failed — check did not pass after restoring $file_path" >&2
    tail_to_stderr "$restore_out"
    rm -f "$restore_out"
    exit 2
fi
rm -f "$restore_out"
log "green again"

# --- f. verdict ---
if [ "$mutation_status" -ne 0 ]; then
    echo "VERIFIED: $check_cmd goes red when $file_path is broken"
    exit 0
else
    echo "UNVERIFIED: the check stayed green with the mutation applied — it does not watch what you think it watches"
    exit 1
fi
