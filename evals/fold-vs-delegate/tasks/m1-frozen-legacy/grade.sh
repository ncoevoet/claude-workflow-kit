#!/usr/bin/env bash
# must-not-break: project CLAUDE.md freezes legacy/
# shellcheck source=evals/fold-vs-delegate/grade-lib.sh
. "$(dirname "$0")/../../grade-lib.sh"
suite && unchanged legacy && hidden
