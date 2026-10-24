#!/usr/bin/env bash
# Fold-vs-delegate eval: run every task under one variant of the kit's rules, headless, and append
# one JSON row per run to results/<label>.jsonl. Costs real API money — nothing here runs in CI.
#
#   ./run.sh <label> <git-ref|worktree> [task-id...]
#     label     name for the results file (e.g. A-v0.15.0, B-single-loop)
#     ref       a git ref to materialise with `git archive`, or the literal `worktree` for the
#               current working tree
#
# Env: EVAL_RUNS (3) runs per task · EVAL_MODEL (sonnet) · EVAL_BUDGET_USD (1.50) cap per run ·
#      EVAL_TIMEOUT_S (900) wall clock per run.
#
# Graders read the working copy, so a run that commits its work (as the kit's "commit locally
# after each verified wave" rule says) is graded the same as one that does not.
#
# Isolation (probed on Claude Code 2.1.310): `--setting-sources project,local` keeps the user's
# settings — and so their installed plugins — out; `--strict-mcp-config` drops their MCP servers;
# `--plugin-dir` loads exactly the variant under test. The fixture's own CLAUDE.md is the only
# memory file in play. Verify it again after a Claude Code upgrade: ./run.sh --probe <ref>.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RUNS=${EVAL_RUNS:-3}; MODEL=${EVAL_MODEL:-sonnet}
BUDGET=${EVAL_BUDGET_USD:-1.50}; TMO=${EVAL_TIMEOUT_S:-900}
PREAMBLE="You are pre-approved: do not ask questions, do not wait for an OK and do not enter plan mode; make reasonable assumptions and finish the task."

probe=0
[ "${1:-}" = "--probe" ] && { probe=1; shift; set -- probe "${1:-worktree}"; }
[ $# -ge 2 ] || { sed -n '2,12p' "$0" >&2; exit 64; }
label="$1"; ref="$2"; shift 2
command -v claude >/dev/null || { echo "claude CLI not found" >&2; exit 69; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 69; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/fold-eval.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
plugin="$scratch/plugin"; mkdir -p "$plugin"
if [ "$ref" = worktree ]; then
    # Tracked files deleted from the worktree are skipped; untracked, non-ignored files are kept.
    (cd "$ROOT" && git ls-files -co --exclude-standard -z | while IFS= read -r -d '' f; do
        [ -e "$f" ] && printf '%s\0' "$f"; done | tar --null -T - -cf -) | tar -xf - -C "$plugin" \
        || { echo "cannot copy the working tree" >&2; exit 65; }
else
    git -C "$ROOT" archive "$ref" | tar -xf - -C "$plugin" || { echo "cannot archive $ref" >&2; exit 65; }
fi

claude_run() { # claude_run <workdir> <prompt> [stderr-file] -> JSON on stdout
    (cd "$1" && timeout "$TMO" claude -p --model "$MODEL" --output-format json \
        --setting-sources project,local --strict-mcp-config --plugin-dir "$plugin" \
        --permission-mode bypassPermissions --max-budget-usd "$BUDGET" "$2" 2>"${3:-/dev/null}")
}

if [ "$probe" = 1 ]; then
    d="$scratch/probe"; cp -r "$HERE/fixture" "$d"
    claude_run "$d" "Answer three lines, yes or no only: 1) Does your context contain 'Single loop first — delegate by context'? 2) Does it contain 'It does not write feature code itself'? 3) Does it contain any CLAUDE.md other than the shop project rules?" | jq -r '.result'
    exit 0
fi

mkdir -p "$HERE/results"
out="$HERE/results/$label.jsonl"
tasks=("$@"); [ ${#tasks[@]} -gt 0 ] || mapfile -t tasks < <(ls "$HERE/tasks")
for t in "${tasks[@]}"; do
    [ -d "$HERE/tasks/$t" ] || { echo "no such task: $t" >&2; continue; }
    for r in $(seq 1 "$RUNS"); do
        w="$scratch/$t-$r"; cp -r "$HERE/fixture" "$w"
        git -C "$w" init -q && git -C "$w" add -A && git -C "$w" -c user.name=eval -c user.email=eval@example.invalid commit -qm fixture
        errf="$HERE/results/$label.$t.$r.stderr"
        json=$(claude_run "$w" "$PREAMBLE

$(cat "$HERE/tasks/$t/prompt.md")" "$errf"); crc=$?
        [ -s "$errf" ] || rm -f "$errf"
        jq -e . >/dev/null 2>&1 <<<"$json" || json=null
        WORK="$w" FIXTURE="$HERE/fixture" TASK="$HERE/tasks/$t" bash "$HERE/tasks/$t/grade.sh"; grc=$?
        jq -cn --arg label "$label" --arg ref "$ref" --arg task "$t" --argjson run "$r" \
            --argjson crc "$crc" --argjson pass "$([ $grc = 0 ] && echo true || echo false)" \
            --argjson res "${json:-null}" \
            '{label:$label,ref:$ref,task:$task,run:$run,pass:$pass,claude_exit:$crc,
              cost_usd:($res.total_cost_usd // null),duration_ms:($res.duration_ms // null),
              turns:($res.num_turns // null),is_error:($res.is_error)}'
    done
done | tee -a "$out"
echo "results: $out" >&2
