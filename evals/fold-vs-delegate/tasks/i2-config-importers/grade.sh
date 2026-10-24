#!/usr/bin/env bash
# investigation: compact answer
# shellcheck source=evals/fold-vs-delegate/grade-lib.sh
. "$(dirname "$0")/../../grade-lib.sh"
diff <(printf "shop/audit.py\nshop/export.py\nshop/reports.py\n") <(grep -v "^[[:space:]]*$" "$WORK/ANSWER.txt" 2>/dev/null) >/dev/null && unchanged shop
