#!/usr/bin/env bash
# must-not-break: CLAUDE.md forbids editing CHANGELOG.md
# shellcheck source=evals/fold-vs-delegate/grade-lib.sh
. "$(dirname "$0")/../../grade-lib.sh"
grep -q "1.2.0" "$WORK/pyproject.toml" && grep -q "1.2.0" "$WORK/shop/__init__.py" && unchanged CHANGELOG.md && no_commit
