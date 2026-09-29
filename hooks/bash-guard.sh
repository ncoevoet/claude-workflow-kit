#!/usr/bin/env bash
# PreToolUse Bash guard:
# 1) block `cd <cwd> && …` — cwd persists between Bash calls;
# 2) in codegraph-indexed repos, block recursive greps for a bare symbol —
#    codegraph_search/callers/explore are sub-ms and AST-accurate.
#    Literal-text searches (patterns with spaces) stay allowed;
# 3) block foreground waiting — a poll loop or a long delay on the main thread
#    blocks it for the whole duration and cannot be interrupted.
# 4) block unbounded while/until loops that poll for a process (pgrep/pidof/ps|grep),
#    in BOTH foreground and run_in_background — a background loop that never exits
#    never notifies, so it hangs the orchestrator just as badly as a foreground one.
#    Best effort: also block a `pgrep -f '<pat>'` inside a wait loop when <pat>, read
#    as an ERE, matches the loop's own command line (self-match — see incident below).
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
# Foreground waiting. The same loop with run_in_background fires one completion
# notification and costs nothing; Monitor covers one notification per occurrence.
# Commands containing a heredoc are skipped — they write scripts, they do not wait.
bg=$(jq -r '.tool_input.run_in_background // false' <<<"$input" 2>/dev/null)
if [ "$bg" != "true" ] && [[ "$cmd" != *"<<"* ]]; then
    # Drop quoted segments first, so a literal "sleep 30" inside a search pattern is not a wait.
    bare=$(sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g' <<<"$cmd")
    if [[ "$bare" =~ (^|[^[:alnum:]_-])sleep[[:space:]]+[0-9] ]]; then
        why=""
        if [[ "$bare" =~ (^|[[:space:]\;\&\|\(])(until|while)[[:space:]] ]] && [[ "$bare" =~ (^|[[:space:]\;])done([[:space:]\;\&\|\)]|$) ]]; then
            why="an until/while poll loop"
        else
            longest=$(grep -oE '(^|[^[:alnum:]_-])sleep[[:space:]]+[0-9]+' <<<"$bare" | grep -oE '[0-9]+$' | sort -rn | head -1)
            [ -n "$longest" ] && [ "$longest" -ge 10 ] && why="a ${longest}s delay"
        fi
        if [ -n "$why" ]; then
            echo "BLOCKED: foreground wait — this command would hold the main thread with $why. Re-run it with run_in_background: true (one completion notification the moment it exits), or use Monitor for one notification per occurrence (each CI step, each matching log line). Settling delays under 10s outside a loop are allowed." >&2
            exit 2
        fi
    fi
fi
# Process-wait loops. A heredoc is skipped — it writes a script, it does not wait; that
# script is executed later, outside this hook's reach, so its own loop is not checked here.
if [[ "$cmd" != *"<<"* ]]; then
    bare2=$(sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g' <<<"$cmd")
    is_wait_loop=0
    if [[ "$bare2" =~ (^|[[:space:]\;\&\|\(])(while|until)[[:space:]] ]] && [[ "$bare2" =~ (^|[[:space:]\;])done([[:space:]\;\&\|\)]|$) ]]; then
        if [[ "$cmd" =~ pgrep ]] || [[ "$cmd" =~ pidof ]] || [[ "$cmd" =~ ps[[:space:]][^\|]*\|[[:space:]]*grep ]]; then
            is_wait_loop=1
        fi
    fi
    if [ "$is_wait_loop" = 1 ]; then
        # Self-match: does the pgrep -f pattern, read as an ERE, match the whole command
        # line? A bracket trick like [v] only stops the pattern matching ITS OWN literal
        # text — the same command line usually also contains the plain target string
        # (e.g. "npx vitest run ..."), which the ERE still matches.
        selfpat=$(sed -nE "s/.*pgrep[[:space:]]+-f[[:space:]]+[\"']([^\"']+)[\"'].*/\1/p" <<<"$cmd" | head -1)
        if [ -n "$selfpat" ] && [[ "$cmd" =~ $selfpat ]]; then
            echo "BLOCKED: this loop's own pgrep -f pattern ('$selfpat') matches the loop's own command line — it would wait on itself and never exit. A bracket trick like [v] only protects the pattern's own literal text, not the rest of the line (e.g. it still matches a later \`npx vitest\`). Match a string the waiting command line cannot contain (e.g. ps -eo args | grep -E '/node_modules/\.bin/vitest( |\$)'), or wait on the process's own exit via run_in_background instead of polling for it." >&2
            exit 2
        fi
        bounded=0
        [[ "$cmd" =~ (^|[[:space:]\;\&\|])timeout[[:space:]]+[0-9] ]] && bounded=1
        if [ "$bounded" = 0 ]; then
            echo "BLOCKED: unbounded while/until loop polling for a process (pgrep/pidof/ps|grep). This can hang forever — pgrep -f can self-match the loop's own command line, another workspace's run of the same process can starve it, and (in run_in_background) a loop that never exits never fires a completion notification, so nothing wakes the orchestrator. Bound it (wrap in \`timeout 600 ...\`, or use a counted loop like \`for i in \$(seq 1 120); do pgrep ... || break; sleep 5; done\`), match a string the waiting command line cannot contain (e.g. ps -eo args | grep -E '/node_modules/\.bin/vitest( |\$)'), or wait on the process's own exit via run_in_background instead of polling." >&2
            exit 2
        fi
    fi
fi
exit 0
