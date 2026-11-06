#!/usr/bin/env bash
# PreToolUse gate for ExitPlanMode, Edit|Write and Bash: refuse non-trivial work until the
# Groundwork SPEC phase produced a spec AND recorded its adversarial review. A Bash command that
# writes files (sed -i, redirects, tee, interpreter scripts) is gated per written file, like an Edit.
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
# `~/.claude/plans/*-agent-*.md`) carrying a reviewed `## Adversarial review`, carry that section
# inline (the main thread's own plan file), or declare `Spec: none — <reason>`.
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
    # An explicit, human-visible waiver for work that genuinely needs no spec. Tolerates
    # markdown decoration: `**Spec:** none`, `- Spec: none`, `> Spec: none`.
    if [ "${#namedok[@]}" -eq 0 ] && grep -qiE '^[[:space:]>*_-]*Spec[*_]*:[*_]*[[:space:]]*none' <<<"$plan"; then
        exit 0
    fi
    # Inline spec: the main thread wrote spec + review into its own plan file. It applies when the
    # plan names no existing spec file — naming the .claude/specs/ target it will be copied to
    # after approval (groundwork phase 4) must not turn into "names a file that does not exist".
    if [ "${#files[@]}" -eq 0 ] && grep -qE '^##[[:space:]]*[Aa]dversarial[[:space:]]+[Rr]eview' <<<"$plan"; then
        if ! inline=$(mktemp 2>/dev/null); then
            echo "Plan approval blocked — cannot create a temp file to validate the inline review." >&2
            exit 2
        fi
        printf '%s\n' "$plan" > "$inline"
        validate_spec "$inline"
        reason=${reason//$inline/the plan}
        rm -f "$inline"
        if [ -z "$reason" ]; then
            # Record the plan file as the Edit pointer only when it is the canonical
            # $HOME/.claude/plans/ file AND itself validates — the Edit path re-reads that file,
            # not the plan text approved here.
            pf=$(jq -r '.tool_input.planFilePath // empty' <<<"$input" 2>/dev/null)
            [ -n "$pf" ] && pf=$(readlink -m "$pf" 2>/dev/null)
            case "$pf" in "$home"/.claude/plans/*.md) [ -f "$pf" ] || pf="" ;; *) pf="" ;; esac
            if [ -n "$pf" ]; then
                validate_spec "$pf"
                if [ -z "$reason" ]; then
                    while IFS= read -r r; do
                        printf '%s\n' "$pf" > "$r/.claude/.spec-gate/current" 2>/dev/null || true
                    done <<<"$roots"
                fi
                reason=""
            fi
            exit 0
        fi
    elif [ "${#namedok[@]}" -eq 0 ]; then
        reason="the plan names no spec (.claude/specs/<slug>.md), carries no inline '## Adversarial review', and has no 'Spec: none — <reason>' waiver"
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
    echo "Groundwork phase 4 (SPEC) runs before phase 5 (GATE): the main thread writes .claude/specs/<slug>.md (in plan mode: inline in its plan file), then an independent opus adversary reviews it. Name that path in the plan, or keep the spec inline." >&2
    echo "Record the adjudicated findings in the spec under '## Adversarial review' — either BLOCKER/GAP/NOTE entries, or 'none found' plus the 6 checks you ran (list items or table rows both count)." >&2
    echo "Work that genuinely needs no spec: put 'Spec: none — <reason>' on its own line in the plan. To disable the gate for a session, set WORKFLOW_SPEC_GATE=off." >&2
    exit 2
fi


# gate_path <file>: the per-file decision shared by Edit|Write and by Bash commands that write
# files. Returns 0 to allow, or prints the block message and returns 2.
gate_path() {
    local path="$1" start root d gate_dir pointer rel spec cand ok a age newest touched now cutoff kept n
    # Canonicalise BEFORE walking: readlink -f returns empty when an intermediate directory
    # does not exist yet, which is the common case for Write.
    case "$path" in /*) ;; *) path="${cwd:-$PWD}/$path" ;; esac
    path=$(readlink -m "$path" 2>/dev/null) || return 0
    start=$(dirname "$path")

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
    [ -n "$root" ] || return 0
    gate_dir="$root/.claude/.spec-gate"
    pointer="$gate_dir/current"

    case "$path" in
        "$root"/*) rel="${path#"$root"/}" ;;
        *) return 0 ;;                    # outside the owning repo — not ours to gate
    esac
    # Writing the spec itself records it, and must never be blocked or the SPEC
    # sub-agent deadlocks against the gate it is arming.
    if [[ "$rel" =~ ^\.claude/specs/.*\.md$ ]]; then
        mkdir -p "$gate_dir" 2>/dev/null || true
        printf '%s\n' "$path" > "$pointer" 2>/dev/null || true
        return 0
    fi
    # Same exclusion set as commit-gate-check.sh: docs and .claude/ are not code.
    grep -qE '(\.md$|^\.claude/|/\.claude/)' <<<"$rel" && return 0

    # --- spec resolution --------------------------------------------------------------
    spec=""
    if [ -f "$pointer" ]; then
        age=$(( ($(date +%s) - $(stat -c %Y "$pointer" 2>/dev/null || echo 0)) / 60 ))
        if [ "$age" -le "$TTL_MIN" ]; then
            cand=$(head -1 "$pointer" 2>/dev/null)
            # The pointer may live under this root, under an ancestor root (nested opt-in), or be a
            # plan-mode file under ~/.claude/plans (only this hook writes the pointer, after
            # validating it); anything else is not ours to trust.
            ok=0
            cand=$(readlink -m "$cand" 2>/dev/null)
            case "$cand" in "$root"/*|"$home"/.claude/plans/*.md) ok=1 ;; esac
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
        [ -z "$reason" ] && return 0
    fi

    # --- free-file budget, shared by Edit|Write and Bash writes ------------------------
    touched="$gate_dir/touched"
    now=$(date +%s); cutoff=$((now - WINDOW_MIN * 60))
    kept=$(awk -v c="$cutoff" -F'\t' '$1 >= c' "$touched" 2>/dev/null)
    n=$(printf '%s\n' "$kept" | awk -F'\t' 'NF>1{print $2}' | sort -u | grep -c .)
    grep -qF "$path" <<<"$kept" || n=$((n + 1))
    if [ "$n" -le "$FREE_FILES" ]; then
        { printf '%s\n' "$kept" | grep -v '^$'; printf '%s\t%s\n' "$now" "$path"; } > "$touched" 2>/dev/null || true
        return 0
    fi

    # --- block ----------------------------------------------------------------------------
    if [ "$tool" = "Bash" ]; then
        echo "Bash write blocked — this command writes $path, and $reason." >&2
        echo "A file written by sed -i, a redirect, tee or an interpreter script counts like an Edit: the spec gate applies to it too." >&2
    else
        echo "Edit blocked — $reason." >&2
    fi
    echo "This is file $n+ in the last ${WINDOW_MIN}m, so it is not a trivial edit. Groundwork phase 4 (SPEC): the main thread writes $root/.claude/specs/<slug>.md, then an independent opus adversary reviews it." >&2
    echo "Record the adjudicated findings in the spec under '## Adversarial review' — either BLOCKER/GAP/NOTE entries, or 'none found' plus the 6 checks you ran (list items or table rows both count)." >&2
    echo "Slug = task lowercased, non-alphanumerics -> '-'. To disable the gate for a session, set WORKFLOW_SPEC_GATE=off." >&2
    return 2
}

# --- Bash: the files a command writes go through the same gate ----------------------------
# Best effort, from the command text: sed/perl -i, awk -i inplace, tee, > and >> redirects,
# and interpreter code (python/node/perl/ruby — inline, heredoc, or a script file named on the
# command line) that calls a file-writing API. A path assembled at runtime is not seen.
if [ "$tool" = "Bash" ]; then
    cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)
    [ -n "$cmd" ] || exit 0
    # The command without heredoc bodies: shell-level writes are read from this, so a `>` inside
    # a script body (a comparison, an arrow function) is never taken for a redirect.
    shell=$(awk '
        skip { if ($0 == term || $0 ~ "^[ \t]*" term "$") skip = 0; next }
        { print }
        match($0, /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*/) {
            term = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*["'"'"']?/, "", term); skip = 1
        }' <<<"$cmd")
    # Path-like tokens: something with an extension, quotes and shell punctuation stripped.
    PATHTOK="[^][[:space:]'\"\`(),;=<>|&{}]+\\.[A-Za-z0-9]{1,8}"
    # Explicit targets (redirect, tee) may name a new file; inferred ones (tokens of an in-place
    # editor line or of interpreter code, full of dotted names like os.path) must name an existing
    # file or carry a directory part, or every attribute access would read as a file.
    targets=""
    add() { targets="${targets:+$targets
}E	$1"; }
    infer() { targets="${targets:+$targets
}I	$1"; }
    # In-place editors: every path-like token on that line is a target.
    # `-i` must be a whole option (-i, -pi, -i.bak, --in-place): a file named list-item.ts is not one.
    if grep -qE '(^|[[:space:];&|(])(sed|perl)[[:space:]]+([^|;&]*[[:space:]])?(-[a-zA-Z]*i(\.[[:alnum:]]+)?|--in-place)([[:space:]=]|$)|(^|[[:space:];&|(])awk[[:space:]]+([^|;&]*[[:space:]])?-i[[:space:]]+inplace' <<<"$shell"; then
        while IFS= read -r t; do infer "$t"; done < <(grep -E '(sed|perl|awk)[[:space:]]' <<<"$shell" | grep -oE "$PATHTOK" | while IFS= read -r t; do printf '%s\n' "$t"; done)
    fi
    # Redirects (not 2>&1, not >&2) and tee.
    while IFS= read -r t; do add "$t"; done < <(grep -oE '[0-9]?>>?[[:space:]]*[^&[:space:];|<>]+' <<<"$shell" \
        | sed -E 's/^[0-9]?>>?[[:space:]]*//' | tr -d "'\"")
    while IFS= read -r t; do add "$t"; done < <(grep -oE '(^|[|[:space:]])tee([[:space:]]+-[a-z]+)*([[:space:]]+[^-|;&[:space:]][^|;&[:space:]]*)+' <<<"$shell" \
        | sed -E 's/^[|[:space:]]*tee//' | tr ' ' '\n' | grep -vE '^(-|$)' | tr -d "'\"")
    # Interpreters: the code is the whole command (inline -c/-e, heredoc body) plus any script
    # file it names; only code that calls a file-writing API contributes targets.
    if grep -qE '(^|[[:space:];&|(])(python[0-9.]*|node|perl|ruby)([[:space:]]|$)' <<<"$shell"; then
        code="$cmd"
        while IFS= read -r s; do
            case "$s" in /*) ;; *) s="${cwd:-$PWD}/$s" ;; esac
            [ -f "$s" ] && code="$code
$(head -c 200000 "$s" 2>/dev/null)"
        done < <(grep -oE '(python[0-9.]*|node|perl|ruby)([[:space:]]+-[A-Za-z]+)*[[:space:]]+[^-[:space:]][^[:space:]]*\.(py|js|mjs|cjs|pl|rb)' <<<"$shell" \
            | awk '{print $NF}' | tr -d "'\"")
        if grep -qE "write_text|write_bytes|\.write\(|open\([^)]*,[[:space:]]*['\"][wax]|writeFileSync|appendFileSync|createWriteStream|shutil\.(copy|move)|os\.(replace|rename)|File\.write" <<<"$code"; then
            while IFS= read -r t; do infer "$t"; done < <(grep -oE "$PATHTOK" <<<"$code")
        fi
    fi
    [ -n "$targets" ] || exit 0
    while IFS=$'\t' read -r kind t; do
        [ -n "$t" ] || continue
        case "$t" in \~/*) t="$HOME/${t#\~/}" ;; esac
        case "$t" in /*) abs="$t" ;; *) abs="${cwd:-$PWD}/$t" ;; esac
        abs=$(readlink -m "$abs" 2>/dev/null) || continue
        [ -d "$abs" ] && continue
        if [ "$kind" = I ]; then
            [ -f "$abs" ] || { [[ "$t" == */* ]] && [ -d "$(dirname "$abs")" ]; } || continue
        else
            [ -e "$abs" ] || [ -d "$(dirname "$abs")" ] || continue
        fi
        gate_path "$abs" || exit 2
    done < <(awk '!seen[$0]++' <<<"$targets")
    exit 0
fi

# Neither a file nor ExitPlanMode: nothing to gate.
[ -n "$path" ] || exit 0
gate_path "$path"
exit $?
