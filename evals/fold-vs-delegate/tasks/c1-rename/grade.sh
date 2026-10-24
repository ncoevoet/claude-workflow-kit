#!/usr/bin/env bash
# coupled: one symbol across pricing, orders, formatter, tests
# shellcheck source=evals/fold-vs-delegate/grade-lib.sh
. "$(dirname "$0")/../../grade-lib.sh"
suite && ! grep -rq calc_total "$WORK/shop" "$WORK/tests" && hidden
