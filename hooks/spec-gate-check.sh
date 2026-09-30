#!/usr/bin/env bash
# PreToolUse gate for ExitPlanMode and Edit|Write: refuse non-trivial work until the
# Groundwork SPEC phase produced a spec AND recorded its adversarial review.
#
# OPT-IN PER REPOSITORY: exits 0 unless `.claude/.spec-gate/` exists above the target (the edited
# file, or cwd) — or, for ExitPlanMode, above the owner of a `.claude/specs` spec the plan names —
# so installing this plugin never blocks work in repos that do not use the gate:
#   mkdir -p .claude/.spec-gate
#
# Escapes: WORKFLOW_SPEC_GATE=off disables it; the first
# WORKFLOW_SPEC_GATE_FREE_FILES (default 2) distinct files in a
# WORKFLOW_SPEC_GATE_WINDOW_MIN (default 120) minute window are free, so trivial edits
# are not gated. WORKFLOW_SPEC_GATE_TTL_MIN (default 480) bounds how long a written spec keeps the gate open.
#
# ExitPlanMode is gated from the PLAN TEXT, not from prior edits: in plan mode the session has
# edited nothing yet, so an edit-based trigger never fires. The plan must name a fresh spec
# (`.claude/specs/*.md` under an opted-in repo, or a plan-mode agent file
# `~/.claude/plans/*-agent-*.md`) carrying a reviewed `## Adversarial review`, or declare
# `Spec: none — <reason>`.
set -u
[ "${WORKFLOW_SPEC_GATE:-}" = "off" ] && exit 0
# Without jq every field below reads empty; fail open rather than block on a parsing gap.
command -v jq >/dev/null 2>&1 || exit 0
# Canonical HOME: paths are compared after readlink -m, so a symlinked $HOME must be canonical too.
home=$(readlink -m "$HOME" 2>/dev/null || printf '%s' "$HOME")

FREE_FILES=${WORKFLOW_SPEC_GATE_FREE_FILES:-2}
WINDOW_MIN=${WORKFLOW_SPEC_GATE_WINDOW_MIN:-120}
TTL_MIN=${WORKFLOW_SPEC_GATE_TTL_MIN:-480}

input=$(cat)
path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input" 2>/dev/null)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
tool=$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)

# validate_spec <file>: sets `reason` (empty = the spec carries a real review). It never covers
# "no spec found" — callers decide what a missing file means.
validate_spec() {
    local body n
    reason=""
    body=$(awk '/^##[[:space:]]*[Aa]dversarial[[:space:]]+[Rr]eview/{f=1;next} f&&/^## /{exit} f' "$1")
    if [ -z "$(tr -d '[:space:]' <<<"$body")" ]; then
        reason="$1 has no '## Adversarial review' section"
    elif [ "$(grep -cve '^[[:space:]]*$' <<<"$body")" -lt 3 ]; then
        reason="the '## Adversarial review' section in $1 is too thin to be a real review"
    elif grep -qE '\b(BLOCKER|GAP|NOTE)\b' <<<"$body"; then
        :
    elif grep -qiE 'none found|no findings|nothing found' <<<"$body"; then
        n=$(grep -cE '^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]|^[[:space:]]*\|' <<<"$body")
        # A markdown table costs 2 lines of header/separator before any real row.
        grep -qE '^[[:space:]]*\|' <<<"$body" && n=$((n - 2))
        [ "$n" -ge 6 ] || reason="the review in $1 says 'none found' but enumerates only $n of the 6 checks"
    else
        reason="the '## Adversarial review' section in $1 lists no BLOCKER/GAP/NOTE and does not state 'none found'"
    fi
}

# collect_roots <dir>: append every ancestor-or-self of <dir> that owns .claude/.spec-gate to
# $roots (newline-separated, deduped). ALL of them, not the nearest: repos nest (a sub-project
# opted in inside an opted-in monorepo) and a plan's spec may live in either.
roots=""
collect_roots() {
    local d="$1"
    [ -n "$d" ] || return 0
    while :; do
        if [ -d "$d/.claude/.spec-gate" ] && ! grep -qxF "$d" <<<"$roots"; then
            roots="${roots:+$roots
}$d"
        fi
        [ "$d" = "/" ] && break
        d=$(dirname "$d")
    done
}

# --- ExitPlanMode: gate from the plan text -----------------------------------------------
if [ "$tool" = "ExitPlanMode" ]; then
    plan=$(jq -r '.tool_input.plan // empty' <<<"$input" 2>/dev/null)
    if [ -z "$plan" ]; then
        pf=$(jq -r '.tool_input.planFilePath // empty' <<<"$input" 2>/dev/null)
        [ -n "$pf" ] && [ -f "$pf" ] && [ -r "$pf" ] && plan=$(cat "$pf" 2>/dev/null)
    fi
    start="${cwd:-${CLAUDE_PROJECT_DIR:-}}"
    [ -n "$start" ] && start=$(readlink -m "$start" 2>/dev/null)
    collect_roots "$start"
    top=""
    [ -n "$start" ] && top=$(git -C "$start" rev-parse --show-toplevel 2>/dev/null)
    # Paths with spaces are unsupported; markup characters and globs end a path.
    # `[ ] , : =` end a path too: markdown links, `Spec:/abs/x.md` and `x,.claude/...` glue them on.
    NC="[^][[:space:]\`'\"()<>*?,:=]"
    mapfile -t named < <(grep -oE -e "${NC}*\\.claude/specs/${NC}+\\.md" \
                                  -e "${NC}*\\.claude/plans/${NC}*-agent-${NC}*\\.md" <<<"$plan" | awk '!seen[$0]++')
    # resolve <named path> -> the existing file it points at, or empty. A relative path is tried
    # against cwd, the git toplevel, then each opted-in root: plans quote repo-relative paths.
    resolve() {
        local c="$1" b
        case "$c" in \~/*) c="$HOME/${c#\~/}" ;; esac
        if [[ "$c" == /* ]]; then
            [ -f "$c" ] && readlink -m "$c"
            return 0
        fi
        for b in "$start" "$top" $(printf '%s\n' "$roots"); do
            [ -n "$b" ] && [ -f "$b/$c" ] && { readlink -m "$b/$c"; return 0; }
        done
        return 0
    }
    files=(); missing=(); namedok=()
    for c in "${named[@]}"; do
        cc="$c"
        case "$cc" in \~/*) cc="$HOME/${cc#\~/}" ;; esac
        if [[ "$c" == *.claude/specs/* ]]; then
            f=$(resolve "$c")
        else
            # A plan-mode agent file counts only under the canonical $HOME/.claude/plans/: any other
            # `.claude/plans/*-agent-*.md` is somebody else's file, not a spec.
            [[ "$cc" == /* ]] || continue
            f=$(readlink -m "$cc")
            case "$f" in "$home"/.claude/plans/*-agent-*.md) ;; *) continue ;; esac
            [ -f "$f" ] || f=""
        fi
        namedok+=("$c")
        # The owner walk also runs for a named spec that does not exist: opt-in is decided first.
        o="${f:-$c}"
        case "$o" in
            /*/.claude/specs/*) collect_roots "${o%/.claude/specs/*}" ;;
        esac
        if [ -n "$f" ]; then files+=("$f"); else missing+=("$c"); fi
    done
    # Nowhere opted in (neither cwd nor any named spec's owner) — stay out of the way.
    [ -n "$roots" ] || exit 0
    reason=""
    if [ "${#namedok[@]}" -eq 0 ]; then
        # An explicit, human-visible waiver for work that genuinely needs no spec. Tolerates
        # markdown decoration: `**Spec:** none`, `- Spec: none`, `> Spec: none`.
        grep -qiE '^[[:space:]>*_-]*Spec[*_]*:[*_]*[[:space:]]*none' <<<"$plan" && exit 0
        reason="the plan names no spec (.claude/specs/<slug>.md) and carries no 'Spec: none — <reason>' waiver"
    elif [ "${#missing[@]}" -gt 0 ]; then
        reason="the plan names ${missing[0]}, which does not exist"
    else
        for f in "${files[@]}"; do
            # A stale spec must not reopen the gate (the pointer is rewritten fresh below).
            age=$(( ($(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0)) / 60 ))
            if [ "$age" -gt "$TTL_MIN" ]; then
                reason="$f is older than ${TTL_MIN} min — re-review or rewrite it"
                break
            fi
            # A repo spec must belong to an opted-in root: a foreign repo's spec approves nothing here.
            if [[ "$f" == */.claude/specs/* ]]; then
                inroot=0
                while IFS= read -r r; do
                    case "$f" in "$r"/*) inroot=1 ;; esac
                done <<<"$roots"
                if [ "$inroot" = 0 ]; then
                    reason="$f is not under an opted-in repository (.claude/.spec-gate)"
                    break
                fi
            fi
            validate_spec "$f"
            [ -n "$reason" ] && break
        done
    fi
    if [ -z "$reason" ]; then
        # Record the LAST named spec in every opted-in root so the Edit path opens the gate
        # from either nesting level.
        while IFS= read -r r; do
            mkdir -p "$r/.claude/.spec-gate" 2>/dev/null || true
            printf '%s\n' "${files[${#files[@]}-1]}" > "$r/.claude/.spec-gate/current" 2>/dev/null || true
        done <<<"$roots"
        exit 0
    fi
    echo "Plan approval blocked — $reason." >&2
    echo "Groundwork phase 4 (SPEC) runs before phase 5 (GATE): a dedicated sub-agent writes .claude/specs/<slug>.md (in plan mode: its agent plan file), then a second, independent opus adversary reviews it. Name that path in the plan." >&2
    echo "Record the adjudicated findings in the spec under '## Adversarial review' — either BLOCKER/GAP/NOTE entries, or 'none found' plus the 6 checks you ran (list items or table rows both count)." >&2
    echo "Work that genuinely needs no spec: put 'Spec: none — <reason>' on its own line in the plan. To disable the gate for a session, set WORKFLOW_SPEC_GATE=off." >&2
    exit 2
fi

# Canonicalise BEFORE walking: readlink -f returns empty when an intermediate directory
# does not exist yet, which is the common case for Write.
if [ -n "$path" ]; then
    case "$path" in /*) ;; *) path="${cwd:-$PWD}/$path" ;; esac
    path=$(readlink -m "$path" 2>/dev/null) || exit 0
    start=$(dirname "$path")
else
    # Neither a file nor ExitPlanMode: nothing to gate.
    exit 0
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

# --- spec resolution ------------------------------------------------------------------
spec=""
if [ -f "$pointer" ]; then
    age=$(( ($(date +%s) - $(stat -c %Y "$pointer" 2>/dev/null || echo 0)) / 60 ))
    if [ "$age" -le "$TTL_MIN" ]; then
        cand=$(head -1 "$pointer" 2>/dev/null)
        # The pointer may live under this root, under an ancestor root (nested opt-in), or be a
        # plan-mode agent file under ~/.claude/plans; anything else is not ours to trust.
        ok=0
        cand=$(readlink -m "$cand" 2>/dev/null)
        case "$cand" in "$root"/*|"$home"/.claude/plans/*-agent-*.md) ok=1 ;; esac
        if [ "$ok" = 0 ]; then
            a=$(dirname "$root")
            while :; do
                if [ -d "$a/.claude/.spec-gate" ]; then case "$cand" in "$a"/*) ok=1; break ;; esac; fi
                [ "$a" = "/" ] && break
                a=$(dirname "$a")
            done
        fi
        [ "$ok" = 1 ] && [ -f "$cand" ] && spec="$cand"
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
    validate_spec "$spec"
    [ -z "$reason" ] && exit 0
fi

# --- free-file budget (edits only; ExitPlanMode is decided above, from the plan text) ---
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

# --- block (Edit|Write only; ExitPlanMode blocks above) ---------------------------------
echo "Edit blocked — $reason." >&2
echo "This is file $n+ in the last ${WINDOW_MIN}m, so it is not a trivial edit. Groundwork phase 4 (SPEC): a dedicated sub-agent writes $root/.claude/specs/<slug>.md, then a second, independent opus adversary reviews it." >&2
echo "Record the adjudicated findings in the spec under '## Adversarial review' — either BLOCKER/GAP/NOTE entries, or 'none found' plus the 6 checks you ran (list items or table rows both count)." >&2
echo "Slug = task lowercased, non-alphanumerics -> '-'. To disable the gate for a session, set WORKFLOW_SPEC_GATE=off." >&2
exit 2
