#!/usr/bin/env bash
# PreToolUse Bash guard:
# 1) block `cd <cwd> && …` — cwd persists between Bash calls;
# 2) in codegraph-indexed repos, block recursive greps for a bare symbol —
#    codegraph_search/callers/explore are sub-ms and AST-accurate.
#    Literal-text searches (patterns with spaces) stay allowed.
input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
[ -z "$cmd" ] && exit 0
if [[ "$cmd" =~ ^cd[[:space:]]+([^\&\;\|]+)[[:space:]]*\&\& ]]; then
    target="${BASH_REMATCH[1]}"
    target="${target%\"}"; target="${target#\"}"; target="${target%\'}"; target="${target#\'}"
    target="${target%% }"; target="${target%/}"
    target="${target/#\~/$HOME}"
    if [ "$target" = "$cwd" ] || [ "$target" = "." ]; then
        echo "BLOCKED: command starts with 'cd' into the current working directory — cwd persists between Bash calls; run the command directly." >&2
        exit 2
    fi
fi
if [[ "$cmd" =~ grep[[:space:]]+-[a-zA-Z]*r ]]; then
    d="$cwd"; indexed=""
    for _ in 1 2 3 4 5 6; do
        [ -d "$d/.codegraph" ] && { indexed=1; break; }
        [ "$d" = "/" ] && break
        d=$(dirname "$d")
    done
    if [ -n "$indexed" ]; then
        pat=$(sed -nE "s/.*grep[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+)+[\"']([^\"']+)[\"'].*/\2/p" <<<"$cmd" | head -1)
        if [ -n "$pat" ] && [[ ! "$pat" =~ [[:space:]] ]] && [[ "$pat" =~ ^[A-Za-z_\$][A-Za-z0-9_\$.\(\)]*$ ]]; then
            echo "BLOCKED: recursive grep for the symbol '$pat' in a codegraph-indexed repo — use mcp__codegraph__codegraph_search / codegraph_callers / codegraph_explore instead. Literal-text searches (patterns containing spaces) are allowed." >&2
            exit 2
        fi
    fi
fi
exit 0
