#!/usr/bin/env bash
# coupled: model, parser and formatter change together
# shellcheck source=evals/fold-vs-delegate/grade-lib.sh
. "$(dirname "$0")/../../grade-lib.sh"
suite && hidden && no_commit
