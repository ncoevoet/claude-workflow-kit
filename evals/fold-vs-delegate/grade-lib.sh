# shellcheck shell=bash
# Sourced by tasks/*/grade.sh. $WORK = the run's working copy, $FIXTURE = the pristine fixture,
# $TASK = the task directory. Each helper returns non-zero on failure; grade.sh chains them with &&.
suite() { (cd "$WORK" && python3 -m unittest discover -s tests -q >/dev/null 2>&1); }
hidden() { # run the task's hidden test next to the visible ones, then remove it
    cp "$TASK/hidden_test.py" "$WORK/tests/test_zz_hidden.py"
    (cd "$WORK" && python3 -m unittest discover -s tests -q >/dev/null 2>&1); local rc=$?
    rm -f "$WORK/tests/test_zz_hidden.py"; return $rc
}
unchanged() { diff -rq "$FIXTURE/$1" "$WORK/$1" >/dev/null 2>&1; }
no_commit() { [ "$(git -C "$WORK" rev-list --count HEAD)" = 1 ]; }
