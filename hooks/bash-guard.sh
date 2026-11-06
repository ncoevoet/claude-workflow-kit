#!/usr/bin/env bash
# PreToolUse Bash guard:
# 1) block `cd <cwd> && …` — cwd persists between Bash calls;
# 1b) block `git push` with -f/--force/--force-with-lease/+refspec (also -f inside a short
#    cluster such as -fu), and `git add -A`/`--all`/`.` — chained commands and
#    `git -C <dir>` included;
# 2) in codegraph-indexed repos, block recursive greps for a bare symbol —
#    codegraph_explore is sub-ms and AST-accurate. Literal-text and regex searches,
#    and greps whose every path is unindexed or docs/config, stay allowed;
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
# Shell-word tokenizer shared by the git and grep checks. Honours single and double quotes
# and backslash escapes; unquoted `;`, `&`, `|`, newlines and ( ) { } become a lone ";"
# separator token, so quoted text such as 'a|b' stays one word. Best effort: no $(...)
# parsing, no globbing, no expansion — the command text as written. Written in awk (one token
# per output line, a newline inside a quoted word folded to a space, runs of separators
# collapsed) because a per-character bash loop took 16s on a 100 KB command.
TOKS=()
nt=0
if [[ "$cmd" =~ (^|[^[:alnum:]_-])(git|grep)([^[:alnum:]_-]|$) ]]; then
    mapfile -t TOKS < <(printf '%s' "$cmd" | LC_ALL=C awk '
        { s = (NR > 1 ? s "\n" : "") $0 }
        function flush() { if (have) print w; w = ""; have = 0 }
        function sep() { flush(); if (!lastsep) print ";"; lastsep = 1 }
        END {
            n = length(s); q = ""; w = ""; have = 0; lastsep = 1; nh = 0
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (q != "") {
                    if (c == q) q = ""
                    else if (q == "\"" && c == "\\" && i < n) { i++; w = w substr(s, i, 1) }
                    else w = w (c == "\n" ? " " : c)
                    continue
                }
                # Heredoc marker << or <<-, then WORD bare, quoted or backslashed (not the
                # <<< here-string): remember WORD;
                # its body, up to the line that is exactly WORD, is data and never tokenized.
                if (c == "<" && substr(s, i, 2) == "<<" && substr(s, i + 2, 1) != "<") {
                    flush(); j = i + 2; strip = 0
                    if (substr(s, j, 1) == "-") { strip = 1; j++ }
                    while (substr(s, j, 1) == " " || substr(s, j, 1) == "\t") j++
                    d = ""; qc = substr(s, j, 1)
                    if (qc == "\047" || qc == "\"") {
                        j++
                        while (j <= n && substr(s, j, 1) != qc) { d = d substr(s, j, 1); j++ }
                    } else {
                        if (qc == "\\") j++
                        while (j <= n && !index(" \t;&|<>()\n", substr(s, j, 1))) { d = d substr(s, j, 1); j++ }
                        j--
                    }
                    if (d != "") { nh++; hd[nh] = d; hs[nh] = strip }
                    i = j
                    continue
                }
                if (c == "\n" && nh > 0) {
                    # Skip every pending heredoc body, in order, then resume after its delimiter.
                    for (h = 1; h <= nh; h++) {
                        while (i < n) {
                            st = i + 1; e = index(substr(s, st), "\n")
                            e = (e ? st + e - 1 : n + 1)
                            ln = substr(s, st, e - st)
                            if (hs[h]) sub(/^\t+/, "", ln)
                            i = e
                            if (ln == hd[h]) break
                        }
                    }
                    nh = 0; sep(); continue
                }
                if (c == "\047" || c == "\"") { q = c; have = 1; lastsep = 0 }
                else if (c == "\\") { i++; w = w substr(s, i, 1); have = 1; lastsep = 0 }
                else if (c == " " || c == "\t") flush()
                else if (index(";&|\n(){}", c)) sep()
                else { w = w c; have = 1; lastsep = 0 }
            }
            sep()
        }')
    nt=${#TOKS[@]}
fi
# 1b) main-session git safety: no force push (rewrites pushed history) and no blanket
#     staging. Subagents are already denied every state-changing git verb by subagent-guard.sh.
git_block() {
    echo "BLOCKED: $1 Create a new commit instead of rewriting pushed history, and stage explicit paths (git add path/to/file) rather than the whole tree. If the user explicitly asked for a force push, they can run it themselves with \`! git push --force…\`." >&2
    exit 2
}
agent_id=$(jq -r '.agent_id // empty' <<<"$input" 2>/dev/null)
i=0
[ -n "$agent_id" ] && i=$nt   # subagent: subagent-guard.sh already denies every state-changing git verb
while [ "$i" -lt "$nt" ]; do
    # Start of a simple command: skip VAR=val prefixes and transparent wrappers.
    while [ "$i" -lt "$nt" ] && { [[ "${TOKS[i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || [[ "${TOKS[i]}" =~ ^(command|env|sudo|time|nohup|exec)$ ]]; }; do i=$((i + 1)); done
    if [ "$i" -lt "$nt" ] && [[ "${TOKS[i]}" =~ (^|/)git$ ]]; then
        i=$((i + 1))
        # git global options; these take a separate-word value.
        while [ "$i" -lt "$nt" ] && [[ "${TOKS[i]}" == -* ]]; do
            case "${TOKS[i]}" in -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env) i=$((i + 1)) ;; esac
            i=$((i + 1))
        done
        verb="${TOKS[i]:-}"; i=$((i + 1))
        if [ "$verb" = push ] || [ "$verb" = add ]; then
            while [ "$i" -lt "$nt" ] && [ "${TOKS[i]}" != ";" ]; do
                a="${TOKS[i]}"; i=$((i + 1))
                if [ "$verb" = push ]; then
                    case "$a" in
                        --force|--force-with-lease|--force-with-lease=*|--mirror) git_block "\`git push $a\` rewrites remote history." ;;
                        +?*) git_block "\`git push $a\` (a +refspec) force-updates the remote ref." ;;
                        --*) ;;
                        -[A-Za-z0-9]*)
                            # Short-flag cluster (-fu, -uf): -o takes its value attached, so stop there.
                            cl="${a#-}"
                            while [ -n "$cl" ]; do
                                case "${cl:0:1}" in
                                    o) break ;;
                                    f) git_block "\`git push $a\` carries -f and rewrites remote history." ;;
                                esac
                                cl="${cl:1}"
                            done ;;
                    esac
                else
                    case "$a" in
                        --all|.|./) git_block "\`git add $a\` stages the whole working tree." ;;
                        --*) ;;
                        -[A-Za-z]*) [[ "$a" == *A* ]] && git_block "\`git add $a\` stages the whole working tree." ;;
                    esac
                fi
            done
        fi
    fi
    # Advance to the next simple command.
    while [ "$i" -lt "$nt" ] && [ "${TOKS[i]}" != ";" ]; do i=$((i + 1)); done
    i=$((i + 1))
done
# 2) recursive symbol grep. Allowed when the pattern is literal text (whitespace) or a regex
#    (any character outside [A-Za-z0-9_$.], e.g. ( | \), or when every path searched is
#    outside a tree holding .codegraph/, is a .claude dir/path, or is a *.md/*.json/*.yml/
#    *.yaml file or glob — docs and config are not what the symbol index answers.
indexed_path() {
    local d="$1"
    case "$d" in \~) d="$HOME" ;; \~/*) d="$HOME/${d#\~/}" ;; esac
    case "$d" in /*) ;; *) d="${cwd:-$PWD}/$d" ;; esac
    d=$(readlink -m "$d" 2>/dev/null) || return 1
    while [ -n "$d" ]; do
        [ -d "$d/.codegraph" ] && return 0
        [ "$d" = "/" ] && return 1
        d=$(dirname "$d")
    done
    return 1
}
exempt_path() {
    case "$1" in
        .claude|.claude/*|*/.claude|*/.claude/*|*.md|*.json|*.yml|*.yaml) return 0 ;;
    esac
    return 1
}
i=0
while [ "$i" -lt "$nt" ]; do
    if [[ "${TOKS[i]}" =~ (^|/)grep$ ]]; then
        i=$((i + 1)); rec=0; pat=""; havepat=0; paths=(); endopts=0
        while [ "$i" -lt "$nt" ] && [ "${TOKS[i]}" != ";" ]; do
            a="${TOKS[i]}"; i=$((i + 1))
            if [ "$endopts" = 0 ] && [[ "$a" == -?* ]]; then
                case "$a" in
                    --) endopts=1 ;;
                    --recursive|--dereference-recursive) rec=1 ;;
                    --regexp=*) pat="${a#--regexp=}"; havepat=1 ;;
                    --regexp) pat="${TOKS[i]:-}"; havepat=1; i=$((i + 1)) ;;
                    --file|--file=*) [ "$a" = --file ] && i=$((i + 1)); pat=""; havepat=1 ;;
                    --max-count|--context|--after-context|--before-context|--include|--exclude|--exclude-dir|--label|--binary-files|--devices|--directories) i=$((i + 1)) ;;
                    --*) ;;
                    *)
                        cl="${a#-}"
                        while [ -n "$cl" ]; do
                            case "${cl:0:1}" in
                                r|R) rec=1 ;;
                                e) pat="${cl:1}"; [ -z "$pat" ] && { pat="${TOKS[i]:-}"; i=$((i + 1)); }; havepat=1; break ;;
                                f) [ -z "${cl:1}" ] && i=$((i + 1)); pat=""; havepat=1; break ;;
                                m|A|B|C|d|D) [ -z "${cl:1}" ] && i=$((i + 1)); break ;;
                            esac
                            cl="${cl:1}"
                        done ;;
                esac
            elif [ "$havepat" = 0 ]; then
                pat="$a"; havepat=1
            else
                paths+=("$a")
            fi
        done
        if [ "$rec" = 1 ] && [[ "$pat" =~ ^[A-Za-z_\$][A-Za-z0-9_\$.]*$ ]]; then
            [ "${#paths[@]}" -eq 0 ] && paths=(.)
            for p in "${paths[@]}"; do
                exempt_path "$p" && continue
                if indexed_path "$p"; then
                    echo "BLOCKED: recursive grep for the symbol '$pat' in a codegraph-indexed repo — use mcp__codegraph__codegraph_explore instead (one call returns the symbol's source, callers and blast radius). Allowed: literal-text or regex patterns (spaces, ( | \\ …), and paths outside any .codegraph index, under .claude, or *.md/*.json/*.yml/*.yaml files." >&2
                    exit 2
                fi
            done
        fi
    fi
    i=$((i + 1))
done
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
