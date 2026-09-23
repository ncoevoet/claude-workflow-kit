#!/usr/bin/env bash
# PreToolUse guard, SUBAGENTS ONLY: deny state-changing git, project-declared deny
# patterns, and writes to the orchestrator's compaction checkpoint.
#
# --- subagent detection: evidence, not a guess -----------------------------------------
# Claude Code's own hook-input schema carries an `agent_id` field that is populated ONLY
# for subagent-originated tool calls. Two independent pieces of evidence, both read from
# what is actually installed on this machine (no docs fetch needed):
#   1. The local changelog cache (~/.claude/cache/changelog.md, 2.1.x entry):
#        "Added `agent_id` (for subagents) and `agent_type` (for subagents and --agent)
#         to hook events"
#   2. The Claude Code binary itself (strings on the installed CLI executable) computes
#      permission bypass eligibility with the literal expression `isSubagent:!!Q.agent_id`
#      — i.e. the harness's OWN code treats "has agent_id" as the definition of subagent.
# The main session's own tool calls never carry `agent_id`, so `[ -n "$agent_id" ]` below
# is both necessary and sufficient, and this hook is a no-op on the main thread by
# construction — it can never widen into a main-session-wide block.
#
# --- why hooks instead of prose -----------------------------------------------------
# Both rules already existed as plain "never do X" prose (CLAUDE.md / orchestration.md)
# and both were broken by a builder subagent in the same session: one ran an npm script
# that regenerates translations, then `git checkout -- en.json`, silently discarding 18
# uncommitted i18n keys a sibling agent had just added; another overwrote the
# orchestrator's compaction checkpoint file. Prose is advisory; this hook is not.
set -u
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)

agent_id=$(jq -r '.agent_id // empty' <<<"$input" 2>/dev/null)
[ -n "$agent_id" ] || exit 0   # main session — not ours to gate

tool=$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)

report_instead="Report the need back to the orchestrator instead — it owns git state and the compaction checkpoint, and can act on this directly."

case "$tool" in
    Bash)
        cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)
        [ -n "$cmd" ] || exit 0

        # (a) state-changing git verbs. Matches "git <verb>", tolerating up to 8 tokens of
        # git global options between `git` and the verb — including ones that take a
        # separate-word value, like `-C <dir>` or `-c <k=v>`, not just attached ones. The
        # trailing (space|end) after the verb keeps this from firing mid-word inside an
        # unrelated token (e.g. a `commit-msg.txt` argument to `git log`).
        VERBS='add|commit|push|stash|checkout|restore|reset|rebase|merge|cherry-pick|switch|clean'
        GIT_RE="(^|[;&|(]|[[:space:]])git([[:space:]]+[^;&|[:space:]]+){0,8}[[:space:]]+($VERBS)([[:space:]]|\$)"
        if [[ "$cmd" =~ $GIT_RE ]]; then
            echo "BLOCKED: subagents never run state-changing git ($VERBS) — the orchestrator owns git state and hands over a clean index. $report_instead" >&2
            exit 2
        fi

        # (b) project-configured extra deny patterns: <project>/.claude/subagent-deny.txt,
        # one ERE per line, matched against the whole command. Absent file = no extra rules.
        deny=""
        d="$cwd"
        while :; do
            if [ -f "$d/.claude/subagent-deny.txt" ]; then deny="$d/.claude/subagent-deny.txt"; break; fi
            [ "$d" = "/" ] && break
            d=$(dirname "$d")
        done
        if [ -n "$deny" ]; then
            while IFS= read -r pat; do
                [ -n "$pat" ] || continue
                if grep -qE -- "$pat" <<<"$cmd" 2>/dev/null; then
                    echo "BLOCKED: command matches this project's subagent-deny pattern '$pat' ($deny). $report_instead" >&2
                    exit 2
                fi
            done < <(grep -vE '^[[:space:]]*(#|$)' "$deny")
        fi
        exit 0
        ;;
    Write|Edit|MultiEdit|NotebookEdit)
        # (c) the orchestrator's compaction checkpoint is not a subagent's to touch.
        path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input" 2>/dev/null)
        [ -n "$path" ] || exit 0
        case "$path" in /*) ;; *) path="${cwd:-$PWD}/$path" ;; esac
        path=$(readlink -m "$path" 2>/dev/null) || exit 0
        case "$path" in
            */.claude/.compact-gate/*)
                echo "BLOCKED: subagents never write the orchestrator's compaction checkpoint (.claude/.compact-gate/**) — one was overwritten this way already, losing the orchestrator's resumable state. $report_instead" >&2
                exit 2
                ;;
        esac
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
