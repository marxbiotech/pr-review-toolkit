#!/bin/bash
# Tests for scripts/parse-validation-entry.sh
#
# Coverage (the codex-fix-worker Validation: entry grammar):
#   1. `<cmd> -- exit 0`            -> rc=0; stdout: "0\n<cmd>\n"
#   2. `<cmd> -- exit 1`            -> rc=0; stdout: "1\n<cmd>\n"
#   3. `<cmd> -- exit -1`           -> rc=0; signed integers accepted
#   4. `- <cmd> -- exit N`          -> rc=0; leading "- " stripped
#   5. `none possible: <reason>`    -> rc=0; stdout: "none-possible\n<reason>\n"
#   6. `- none possible: <reason>`  -> rc=0; leading "- " stripped
#   7. `<cmd> — exit 0` (em-dash)   -> rc=2; em-dash separator rejected
#   8. `<cmd> - exit 0` (single)    -> rc=2; single-hyphen rejected
#   9. `none possible:` (no reason) -> rc=2; empty reason rejected
#   10. ``                          -> rc=2; empty entry rejected
#   11. `random garbage`            -> rc=2; unrecognized shape rejected
#   12. command containing `bash -c '...'` with `-- exit 0` correctly parsed

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${SCRIPT_DIR:-$ROOT_DIR/scripts}"
SCRIPT="$SCRIPT_DIR/parse-validation-entry.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: script under test not found or not executable: $SCRIPT" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

run_script() {
  local stderr_file
  stderr_file=$(mktemp)
  set +e
  STDOUT=$("$SCRIPT" "$@" 2>"$stderr_file")
  RC=$?
  STDERR=$(cat "$stderr_file")
  set -e
  rm -f "$stderr_file"
}

assert_rc() {
  local label="$1"
  local expected="$2"
  if [ "$RC" != "$expected" ]; then
    echo "FAIL [$label]: expected exit $expected, got $RC" >&2
    echo "  stdout: $STDOUT" >&2
    echo "  stderr: $STDERR" >&2
    exit 1
  fi
}

assert_stdout_eq() {
  local label="$1"
  local expected="$2"
  if [ "$STDOUT" != "$expected" ]; then
    echo "FAIL [$label]: stdout mismatch" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $STDOUT" >&2
    exit 1
  fi
}

# Case 1: simple command, exit 0
run_script "pytest -q -- exit 0"
assert_rc "case1 cmd exit 0" 0
assert_stdout_eq "case1 cmd exit 0" $'0\npytest -q'

# Case 2: simple command, exit 1
run_script "lint --strict -- exit 1"
assert_rc "case2 cmd exit 1" 0
assert_stdout_eq "case2 cmd exit 1" $'1\nlint --strict'

# Case 3: signed integer (negative exit code — unusual but valid)
run_script "tool -- exit -1"
assert_rc "case3 cmd exit -1" 0
assert_stdout_eq "case3 cmd exit -1" $'-1\ntool'

# Case 4: leading "- " prefix stripped
run_script "- jest -- exit 0"
assert_rc "case4 with-leading-dash" 0
assert_stdout_eq "case4 with-leading-dash" $'0\njest'

# Case 5: none possible
run_script "none possible: comment-only edit"
assert_rc "case5 none-possible" 0
assert_stdout_eq "case5 none-possible" $'none-possible\ncomment-only edit'

# Case 6: none possible with leading dash
run_script "- none possible: no covering test exists"
assert_rc "case6 none-possible-with-dash" 0
assert_stdout_eq "case6 none-possible-with-dash" $'none-possible\nno covering test exists'

# Case 7: em-dash separator rejected (the encoding-fragile form must not bypass the ASCII-double-dash contract)
run_script "pytest — exit 0"   # em-dash, not ASCII --
assert_rc "case7 em-dash-rejected" 2

# Case 8: single hyphen rejected (typo of `--`)
run_script "pytest - exit 0"
assert_rc "case8 single-hyphen-rejected" 2

# Case 9: none possible with empty reason
run_script "none possible:"
assert_rc "case9 empty-reason" 2

# Case 10: empty entry
run_script ""
assert_rc "case10 empty" 2

# Case 11: random garbage
run_script "just some text without separator"
assert_rc "case11 garbage" 2

# Case 12: command containing nested `bash -c '...'` with the literal
# ` -- exit ` only at the end. Bash's greedy regex matches the LAST
# occurrence of ` -- exit <N>$`, which is the right behavior for
# legitimately-quoted commands that DO NOT themselves contain ` -- exit `.
run_script "bash -c 'echo hello' -- exit 0"
assert_rc "case12 nested-quoted-cmd" 0
assert_stdout_eq "case12 nested-quoted-cmd" $'0\nbash -c \'echo hello\''

# Case 13: adversarial laundering — multiple ` -- exit <N>` boundaries.
#
# A worker emitting `failing-cmd -- exit 1 -- exit 0` (deliberately or
# accidentally via copy-paste) would have its real failure silently
# laundered through the greedy `.*` regex: parser yields cmd=`failing-cmd
# -- exit 1`, rc=0, which the resolver treats as success. This bypasses
# the safety net the parser was extracted to enforce.
#
# Fix: reject any entry containing the ` -- exit ` substring more than
# once. Workers with legitimate commands containing ` -- exit ` mid-string
# must quote them so the parser sees only one boundary.
run_script "failing-cmd -- exit 1 -- exit 0"
assert_rc "case13 laundering reject" 2

# Case 14: whitespace-only command — `[ -z "$cmd" ]` doesn't catch this.
#
# Verified pre-fix: `parse-validation-entry.sh '   -- exit 0'` returns
# rc=0 with stdout `0\n   ` (3-space cmd). A worker that strips leading
# decoration aggressively (or has a copy-paste bug) could submit this
# and be honored as success with a meaningless cmd label.
run_script "   -- exit 0"
assert_rc "case14 whitespace-only cmd" 2

# Case 15: whitespace-only reason — `[ -z "$reason" ]` after one-space
# trim doesn't catch multi-space reasons.
#
# Verified pre-fix: `parse-validation-entry.sh 'none possible:    '`
# returns rc=0 with stdout `none-possible\n   ` (3-space reason after
# the one-space trim).
run_script "none possible:    "
assert_rc "case15 whitespace-only reason" 2

# Case 16: trailing whitespace on form-1 entry — common from markdown
# editors that add trailing spaces. Should be tolerated (trimmed) rather
# than rejected, since the trailing whitespace is decoration, not signal.
run_script "pytest -q -- exit 0   "
assert_rc "case16 trailing whitespace tolerated" 0
assert_stdout_eq "case16 trailing whitespace tolerated" $'0\npytest -q'

# Case 17: adversarial laundering across a newline boundary.
#
# A multi-line entry containing two ` -- exit ` boundaries (one per line)
# was, pre-fix, silently honored as `rc=0` with `cmd` spanning the newline
# because the awk `print count` statement lived inside the per-record
# block rather than `END`. boundary_count became "1\n1" (two lines of
# output), the `[ ... -gt 1 ]` arithmetic test crashed with `integer
# expression expected`, and `set -e` did NOT abort because the failure
# happened inside an `if` condition. Control fell through to the form-1
# regex which (greedily) matched the last ` -- exit 0$` and emitted rc=0.
# Net effect: a worker that emitted a real failure on line 1 and a
# placebo success on line 2 had its failure laundered into rc=0.
#
# Fix: move awk's `print count` into the `END { ... }` block so the
# boundary count is a single integer regardless of input line count.
# The boundary-count > 1 check then correctly rejects the laundering.
run_script "$(printf 'first -- exit 1\nsecond -- exit 0')"
assert_rc "case17 multi-line laundering reject" 2
if ! printf '%s' "$STDERR" | grep -q 'multiple'; then
  echo "FAIL [case17 multi-line laundering reject]: stderr should name 'multiple boundaries'" >&2
  echo "  stderr: $STDERR" >&2
  exit 1
fi

# Case 18: hypothetical-revert guard for case 17. A single-line single-
# boundary entry must continue to parse correctly after the awk END-
# placement fix — i.e. the fix must not regress the canonical happy path.
# Reverting the fix (moving `print count` back into the main block)
# leaves this case passing but breaks case 17, which is the test pin.
run_script "pytest -q -- exit 0"
assert_rc "case18 post-fix single-line still works" 0
assert_stdout_eq "case18 post-fix single-line still works" $'0\npytest -q'

echo "parse-validation-entry tests passed"
