#!/usr/bin/env bash
# PreToolUse gate for ExitPlanMode and Edit|Write: refuse non-trivial work until the
# Groundwork SPEC phase produced a spec AND recorded its adversarial review.
#
# OPT-IN PER REPOSITORY: exits 0 unless `.claude/.spec-gate/` exists above the target,
# so installing this plugin never blocks work in repos that do not use the gate:
#   mkdir -p .claude/.spec-gate
#
# Escapes: WORKFLOW_SPEC_GATE=off disables it; the first
# WORKFLOW_SPEC_GATE_FREE_FILES (default 2) distinct files in a
# WORKFLOW_SPEC_GATE_WINDOW_MIN (default 120) minute window are free, so trivial edits
# are not gated. WORKFLOW_SPEC_GATE_TTL_MIN (default 480) bounds how long a written spec keeps the gate open.
set -u
[ "${WORKFLOW_SPEC_GATE:-}" = "off" ] && exit 0

FREE_FILES=${WORKFLOW_SPEC_GATE_FREE_FILES:-2}
WINDOW_MIN=${WORKFLOW_SPEC_GATE_WINDOW_MIN:-120}
TTL_MIN=${WORKFLOW_SPEC_GATE_TTL_MIN:-480}

input=$(cat)
path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input" 2>/dev/null)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)

# Canonicalise BEFORE walking: readlink -f returns empty when an intermediate directory
# does not exist yet, which is the common case for Write.
if [ -n "$path" ]; then
    case "$path" in /*) ;; *) path="${cwd:-$PWD}/$path" ;; esac
    path=$(readlink -m "$path" 2>/dev/null) || exit 0
    start=$(dirname "$path")
else
    # ExitPlanMode carries no file. Fall back to cwd, then to the session's project dir.
    start="${cwd:-${CLAUDE_PROJECT_DIR:-}}"
    [ -n "$start" ] || exit 0
    start=$(readlink -m "$start" 2>/dev/null) || exit 0
fi

# Locate the directory that owns .claude/.spec-gate. Uncapped: unlike the commit gate we
# start at a source file, which can sit many levels below the repo root.
root=""
d="$start"
while :; do
    if [ -d "$d/.claude/.spec-gate" ]; then root="$d"; break; fi
    [ "$d" = "/" ] && break
    d=$(dirname "$d")
done
# Not enabled here — stay out of the way.
[ -n "$root" ] || exit 0
gate_dir="$root/.claude/.spec-gate"
pointer="$gate_dir/current"

if [ -n "$path" ]; then
    case "$path" in
        "$root"/*) rel="${path#"$root"/}" ;;
        *) exit 0 ;;                      # outside the owning repo — not ours to gate
    esac
    # Writing the spec itself records it, and must never be blocked or the SPEC
    # sub-agent deadlocks against the gate it is arming.
    if [[ "$rel" =~ ^\.claude/specs/.*\.md$ ]]; then
        mkdir -p "$gate_dir" 2>/dev/null || true
        printf '%s\n' "$path" > "$pointer" 2>/dev/null || true
        exit 0
    fi
    # Same exclusion set as commit-gate-check.sh: docs and .claude/ are not code.
    grep -qE '(\.md$|^\.claude/|/\.claude/)' <<<"$rel" && exit 0
fi

# ExitPlanMode carries no file path, so `root` came from cwd — which is the shell's location,
# not necessarily the repo the plan is about. Refusing a plan on that alone falsely blocks work
# targeting a different repo whenever the shell sits in an opt-in one. Only gate the plan once
# this session has actually edited something here.
if [ -z "$path" ]; then
    now=$(date +%s); cutoff=$((now - WINDOW_MIN * 60))
    recent=$(awk -v c="$cutoff" -F'\t' '$1 >= c' "$gate_dir/touched" 2>/dev/null | grep -c .)
    [ "$recent" -eq 0 ] && exit 0
fi

# --- spec resolution ------------------------------------------------------------------
spec=""
if [ -f "$pointer" ]; then
    age=$(( ($(date +%s) - $(stat -c %Y "$pointer" 2>/dev/null || echo 0)) / 60 ))
    if [ "$age" -le "$TTL_MIN" ]; then
        cand=$(head -1 "$pointer" 2>/dev/null)
        case "$cand" in "$root"/*) [ -f "$cand" ] && spec="$cand" ;; esac
    fi
fi
# Fallback: a spec written before the gate was armed never registered a pointer.
if [ -z "$spec" ]; then
    newest=$(find "$root/.claude/specs" -maxdepth 1 -name '*.md' -mmin "-$((TTL_MIN))" \
             -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    [ -n "$newest" ] && [ -f "$newest" ] && spec="$newest"
fi

reason=""
if [ -z "$spec" ]; then
    reason="no spec found under $root/.claude/specs/ (or the recorded spec expired)"
else
    body=$(awk '/^##[[:space:]]*[Aa]dversarial[[:space:]]+[Rr]eview/{f=1;next} f&&/^## /{exit} f' "$spec")
    if [ -z "$(tr -d '[:space:]' <<<"$body")" ]; then
        reason="$spec has no '## Adversarial review' section"
    elif [ "$(grep -cve '^[[:space:]]*$' <<<"$body")" -lt 3 ]; then
        reason="the '## Adversarial review' section in $spec is too thin to be a real review"
    elif grep -qE '\b(BLOCKER|GAP|NOTE)\b' <<<"$body"; then
        exit 0
    elif grep -qiE 'none found|no findings|nothing found' <<<"$body"; then
        n=$(grep -cE '^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]|^[[:space:]]*\|' <<<"$body")
        # A markdown table costs 2 lines of header/separator before any real row.
        grep -qE '^[[:space:]]*\|' <<<"$body" && n=$((n - 2))
        [ "$n" -ge 6 ] && exit 0
        reason="the review in $spec says 'none found' but enumerates only $n of the 6 checks"
    else
        reason="the '## Adversarial review' section in $spec lists no BLOCKER/GAP/NOTE and does not state 'none found'"
    fi
fi

# --- free-file budget (edits only; the plan path is gated above, on prior edits) ---
if [ -n "$path" ]; then
    touched="$gate_dir/touched"
    now=$(date +%s); cutoff=$((now - WINDOW_MIN * 60))
    kept=$(awk -v c="$cutoff" -F'\t' '$1 >= c' "$touched" 2>/dev/null)
    n=$(printf '%s\n' "$kept" | awk -F'\t' 'NF>1{print $2}' | sort -u | grep -c .)
    grep -qF "$path" <<<"$kept" || n=$((n + 1))
    if [ "$n" -le "$FREE_FILES" ]; then
        { printf '%s\n' "$kept" | grep -v '^$'; printf '%s\t%s\n' "$now" "$path"; } > "$touched" 2>/dev/null || true
        exit 0
    fi
fi

# --- block -----------------------------------------------------------------------------
if [ -n "$path" ]; then
    echo "Edit blocked — $reason." >&2
    echo "This is file $n+ in the last ${WINDOW_MIN}m, so it is not a trivial edit. Groundwork phase 4 (SPEC): a dedicated sub-agent writes $root/.claude/specs/<slug>.md, then a second, independent opus adversary reviews it." >&2
else
    echo "Plan approval blocked — $reason." >&2
    echo "Groundwork phase 4 (SPEC) runs before phase 5 (GATE): a dedicated sub-agent writes $root/.claude/specs/<slug>.md, then a second, independent opus adversary reviews it." >&2
fi
echo "Record the adjudicated findings in the spec under '## Adversarial review' — either BLOCKER/GAP/NOTE entries, or 'none found' plus the 6 checks you ran (list items or table rows both count)." >&2
[ -n "$path" ] && echo "Slug = task lowercased, non-alphanumerics -> '-'. To disable the gate for a session, set WORKFLOW_SPEC_GATE=off." >&2
exit 2
