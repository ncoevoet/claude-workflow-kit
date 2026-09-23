#!/usr/bin/env bash
# SubagentStop gate: enforce project-declared "added-line" rules — e.g. "no // comments",
# "no console.log" — against what a subagent actually wrote, instead of leaving them as
# prose in CLAUDE.md that a builder breaks anyway (evidence: about 80 `//` comments landed
# against the house rule in one session before this existed).
#
# Feedback loop: SubagentStop fires on the STOPPING SUBAGENT's own thread. Claude Code's
# documented hook exit-code contract (exit 2 = block, stderr becomes the reason fed back to
# whoever is stopping, which then continues instead of stopping — the same mechanism
# compact-gate-check.sh uses on PreCompact, changelog: "Added PreCompact hook support: hooks
# can now block compaction by exiting with code 2") applies identically here, so a rule
# violation is handed back to the SUBAGENT that wrote the lines, which can fix it before
# control returns to the orchestrator. A Stop hook on the orchestrator's own thread would
# only interrupt the orchestrator, who did not write the offending lines.
#
# OPT-IN PER PROJECT: exits 0 (no-op) unless <root>/.claude/added-line-rules.txt exists at
# or above the subagent's cwd. Format: one rule per line, tab-separated:
#   <glob><TAB><ERE><TAB><message>
# Blank lines and #-comment lines ignored. The glob is matched with plain shell `case`
# pattern rules (not filesystem globstar), so a bare `*` already spans `/` — "src/*.ts"
# matches "src/sub/a.ts"; there is no "**" syntax and writing one will not match what you
# expect ("src/**/*.ts" needs a literal second "/" a file may not have).
#
# Scope, kept fast on purpose: ONLY added lines — `git diff -U0` "+" lines (tracked files)
# plus untracked new files that match a rule's glob (every line in a brand-new file counts
# as added). One diff, one status call, no full-tree scan, no history walk.
set -u
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
input=$(cat)

cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
[ -n "$cwd" ] || exit 0

# Locate the nearest ancestor of cwd carrying the rules file. The file's mere existence is
# the opt-in signal — there is no separate marker directory to mkdir.
root=""; rules=""
d="$cwd"
while :; do
    if [ -f "$d/.claude/added-line-rules.txt" ]; then root="$d"; rules="$d/.claude/added-line-rules.txt"; break; fi
    [ "$d" = "/" ] && break
    d=$(dirname "$d")
done
[ -n "$rules" ] || exit 0

git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

mapfile -t rule_lines < <(grep -vE '^[[:space:]]*(#|$)' "$rules" 2>/dev/null)
[ "${#rule_lines[@]}" -gt 0 ] || exit 0

# --- gather added lines: tracked files (diff only) --------------------------------------
diff_out=$(git -C "$root" diff -U0 --no-color HEAD -- . 2>/dev/null)
if [ -z "$diff_out" ]; then
    diff_out=$(git -C "$root" diff -U0 --no-color -- . 2>/dev/null)
fi

# path<TAB>lineno<TAB>content, one per added ("+") line. Hunk headers reset the running
# line counter to the addition side's start line; every "+" line after that increments it.
mapfile -t added_lines < <(awk '
    /^\+\+\+ / { f=$2; sub(/^b\//,"",f); next }
    /^@@/ { match($0,/\+[0-9]+/); ln=substr($0,RSTART+1,RLENGTH-1)+0; next }
    /^\+/ && !/^\+\+\+/ { print f "\t" ln "\t" substr($0,2); ln++; next }
' <<<"$diff_out")

# --- gather added lines: untracked new files, only when a rule's glob could match --------
# Read a file's full content only if its path matches at least one rule's glob — this is
# what keeps the check diff-fast even when unrelated large untracked files sit in the tree.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    matched=0
    for rl in "${rule_lines[@]}"; do
        glob="${rl%%$'\t'*}"
        [ -n "$glob" ] || continue
        # shellcheck disable=SC2254 # deliberate unquoted case pattern: $glob is meant to be
        # matched as a shell glob, not as a literal string.
        case "$f" in
            $glob) matched=1; break ;;
        esac
    done
    [ "$matched" -eq 1 ] || continue
    [ -f "$root/$f" ] || continue
    while IFS= read -r rec; do
        [ -n "$rec" ] && added_lines+=("$rec")
    done < <(awk -v file="$f" '{print file "\t" NR "\t" $0}' "$root/$f" 2>/dev/null)
done < <(git -C "$root" ls-files --others --exclude-standard 2>/dev/null)

[ "${#added_lines[@]}" -gt 0 ] || exit 0

# --- evaluate every rule against every added line ----------------------------------------
violations=()
for rl in "${rule_lines[@]}"; do
    IFS=$'\t' read -r glob ere msg <<<"$rl"
    if [ -z "$glob" ] || [ -z "$ere" ]; then continue; fi
    for al in "${added_lines[@]}"; do
        IFS=$'\t' read -r file lineno content <<<"$al"
        [ -n "$file" ] || continue
        # shellcheck disable=SC2254 # deliberate unquoted case pattern: $glob is meant to be
        # matched as a shell glob, not as a literal string.
        case "$file" in
            $glob) ;;
            *) continue ;;
        esac
        if grep -qE -- "$ere" <<<"$content" 2>/dev/null; then
            violations+=("$file:$lineno: $msg")
        fi
    done
done

[ "${#violations[@]}" -gt 0 ] || exit 0

{
    echo "BLOCKED: added-line rule violation(s) in $rules — fix these before finishing:"
    printf '  %s\n' "${violations[@]}"
    echo "Report the fix in your final report; do not leave this for the orchestrator to clean up."
} >&2
exit 2
