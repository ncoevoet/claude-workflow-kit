#!/usr/bin/env bash
# investigation: compact answer
# shellcheck source=evals/fold-vs-delegate/grade-lib.sh
. "$(dirname "$0")/../../grade-lib.sh"
line=$( { tr -d "[:space:]" < "$WORK/ANSWER.txt"; } 2>/dev/null); [ "$line" = "shop/checkout.py:amount_due" ] && unchanged shop && no_commit
