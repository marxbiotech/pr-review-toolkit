#!/bin/bash
# Tests for scripts/check-pr-round-identifiers.sh
#
# This script is the structural escape valve against PR-round identifiers
# (R<round>-<class><number>, e.g. R7-C1) leaking into committed source.
# Such identifiers rot after PR merge — no future maintainer knows what
# they refer to once the PR thread is gone. The lint was previously
# inlined into .github/workflows/validate.yml, where it was untested and
# accumulated multiple rounds of silent-failure bugs (stderr swallow,
# narrow regex, missing scan paths). Extracting it to a script with a
# test suite pins each behavioral guarantee against future revert.
#
# Coverage:
#   1.  Violation under a scanned dir              -> rc=1 + match on stdout
#   2.  Clean scan tree                            -> rc=0 + success message
#   3.  Nonexistent scan path                      -> rc>=2 + grep stderr surfaced
#                                                    (pins R7-I1: previous form
#                                                     used 2>/dev/null which
#                                                     collapsed "missing" with
#                                                     "no matches".)
#   4.  Lowercase variant (r7-c1)                  -> rc=1 (pins -i from R7-I2)
#   5.  Future class letter (R8-Q1, Q ∉ [CIS])     -> rc=1 (pins [A-Z] broadening
#                                                          from R7-I2)
#   6.  Word boundary - leading alpha (MR3-C1)     -> rc=0 (commercial part
#                                                          number must NOT match)
#   7.  Word boundary - trailing alpha (R5-S4abc)  -> rc=0 (longer identifier
#                                                          must NOT match)
#   8.  README.md excluded                         -> rc=0 (historical
#                                                          change-log entries
#                                                          are tolerated)
#   9.  .pr-review-cache/ excluded                 -> rc=0 (gitignored cache
#                                                          may legitimately
#                                                          carry R-numbers)
#   10. R8-I1 regression pin: rc=0 (match found)
#       AND grep emits stderr                      -> script must surface the
#                                                    stderr, not silently drop
#                                                    it via the EXIT trap's
#                                                    rm -f. Triggered via a
#                                                    PATH-injected fake grep
#                                                    that emits both a match
#                                                    and a warning, then exits
#                                                    0. Pre-R8-I1 form swallowed
#                                                    the stderr on the match-
#                                                    found branch.
#   11. Script self-exclusion pin: a fixture file
#       named check-pr-round-identifiers.sh that
#       contains a literal R-number string must NOT
#       cause the lint to fail -> rc=0 + success
#       message (the --exclude=check-pr-round-
#       identifiers.sh flag is load-bearing;
#       reverting it would make the lint self-fail
#       on its own definition file because the
#       script header carries R-number example
#       identifiers).
#   12. Test self-exclusion pin: same as case 11
#       but for the test filename — a fixture file
#       named check-pr-round-identifiers-test.sh
#       must be skipped via the matching --exclude
#       flag -> rc=0 + success message (the test
#       file carries 30+ literal R-numbers as
#       fixtures and rationale).
#   13. Default-args invocation at repo root: the
#       actual CI invocation runs with NO positional
#       args, scanning the script's hard-coded
#       default-path array. All other cases pass an
#       explicit fixture dir; only this case
#       exercises the end-to-end CI contract -> rc=0
#       + success message. Pins against the rename-
#       induced silent-breakage scenario where one
#       byte-equal script copy is renamed and the
#       basename-match --exclude= silently fails to
#       protect it.
#
# Each case runs against a fixture dir or PATH-injected helper. No git
# repo is required (the script does not invoke git).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${SCRIPT_DIR:-$ROOT_DIR/scripts}"
SCRIPT="$SCRIPT_DIR/check-pr-round-identifiers.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: script under test not found or not executable: $SCRIPT" >&2
  exit 1
fi

# Helpers

run_script() {
  # Capture stdout, stderr, and exit code separately, mirroring the
  # check-fix-worker-scope-test.sh pattern. Per-invocation mktemp so
  # concurrent runs cannot race.
  local stderr_file
  stderr_file=$(mktemp)
  set +e
  STDOUT=$("$SCRIPT" "$@" 2>"$stderr_file")
  RC=$?
  STDERR=$(cat "$stderr_file")
  set -e
  rm -f "$stderr_file"
}

run_script_with_path() {
  # Same as run_script but with a custom PATH prefix (for case 10's
  # fake-grep injection).
  local extra_path="$1"
  shift
  local stderr_file
  stderr_file=$(mktemp)
  set +e
  STDOUT=$(PATH="$extra_path:$PATH" "$SCRIPT" "$@" 2>"$stderr_file")
  RC=$?
  STDERR=$(cat "$stderr_file")
  set -e
  rm -f "$stderr_file"
}

run_script_in_dir() {
  # Same as run_script but with cwd changed to a specified directory.
  # The cd happens inside the $(...) subshell so it does not leak to
  # subsequent test code. Used by the default-args case to exercise
  # the script's hard-coded default-path array, which is relative-
  # path-based and only resolves correctly when cwd = repo root.
  local dir="$1"
  shift
  local stderr_file
  stderr_file=$(mktemp)
  set +e
  STDOUT=$(cd "$dir" && "$SCRIPT" "$@" 2>"$stderr_file")
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

assert_rc_at_least() {
  local label="$1"
  local minimum="$2"
  if [ "$RC" -lt "$minimum" ]; then
    echo "FAIL [$label]: expected exit >= $minimum, got $RC" >&2
    echo "  stdout: $STDOUT" >&2
    echo "  stderr: $STDERR" >&2
    exit 1
  fi
}

assert_stdout_contains() {
  local label="$1"
  local needle="$2"
  if [[ "$STDOUT" != *"$needle"* ]]; then
    echo "FAIL [$label]: stdout missing expected substring" >&2
    echo "  expected substring: $needle" >&2
    echo "  actual stdout: $STDOUT" >&2
    exit 1
  fi
}

assert_stderr_contains() {
  local label="$1"
  local needle="$2"
  if [[ "$STDERR" != *"$needle"* ]]; then
    echo "FAIL [$label]: stderr missing expected substring" >&2
    echo "  expected substring: $needle" >&2
    echo "  actual stderr: $STDERR" >&2
    exit 1
  fi
}

assert_stderr_empty() {
  local label="$1"
  if [ -n "$STDERR" ]; then
    echo "FAIL [$label]: expected empty stderr, got non-empty content" >&2
    echo "  actual stderr: $STDERR" >&2
    exit 1
  fi
}

make_fixture_dir() {
  FIXTURE_DIR=$(mktemp -d)
}

cleanup_fixture_dir() {
  # Restore any chmod-000 dirs so rm can recurse.
  if [ -n "${FIXTURE_DIR:-}" ] && [ -d "$FIXTURE_DIR" ]; then
    chmod -R u+rwX "$FIXTURE_DIR" 2>/dev/null || true
    rm -rf "$FIXTURE_DIR"
  fi
  FIXTURE_DIR=""
}

# Case 1: violation in a scanned file -> rc=1 + match on stdout

make_fixture_dir
echo "this references R7-C1 inline" > "$FIXTURE_DIR/bad.sh"
run_script "$FIXTURE_DIR"
assert_rc "case1 violation rc" 1
assert_stdout_contains "case1 violation stdout" "R7-C1"
assert_stdout_contains "case1 violation stdout has path" "bad.sh"
cleanup_fixture_dir

# Case 2: clean scan tree -> rc=0 + success message

make_fixture_dir
echo "no pr-round identifiers here, just a normal script" > "$FIXTURE_DIR/good.sh"
run_script "$FIXTURE_DIR"
assert_rc "case2 clean rc" 0
assert_stdout_contains "case2 clean stdout" "No PR-round identifiers"
cleanup_fixture_dir

# Case 3: nonexistent scan path -> rc>=2 + grep stderr surfaced
#
# This pins R7-I1: previous form used `grep ... 2>/dev/null` which
# silently masked "scan target missing" as "no matches found".
# Reverting to 2>/dev/null would make this test fail (STDERR would
# no longer contain grep's "No such file or directory" message).

run_script "/nonexistent/path/that/should/not/exist/$$"
assert_rc_at_least "case3 missing-target rc" 2
assert_stderr_contains "case3 missing-target stderr" "No such file"
cleanup_fixture_dir

# Case 4: lowercase variant (r7-c1) -> rc=1
#
# Pins the `-i` flag from R7-I2. Reverting `-i` would make grep miss
# this case and return rc=0 (false-clean).

make_fixture_dir
echo "informal reference to r7-c1 in a comment" > "$FIXTURE_DIR/lower.sh"
run_script "$FIXTURE_DIR"
assert_rc "case4 lowercase rc" 1
assert_stdout_contains "case4 lowercase stdout" "r7-c1"
cleanup_fixture_dir

# Case 5: future class letter (R8-Q1) -> rc=1
#
# Pins the `[A-Z]` class broadening from R7-I2. Reverting to `[CIS]`
# would miss any future round classification (Q for question, B for
# blocker, etc.) and return rc=0 (false-clean).

make_fixture_dir
echo "R8-Q1 means a hypothetical Question-class finding" > "$FIXTURE_DIR/future.sh"
run_script "$FIXTURE_DIR"
assert_rc "case5 future-class rc" 1
assert_stdout_contains "case5 future-class stdout" "R8-Q1"
cleanup_fixture_dir

# Case 6: word boundary - leading alpha (MR3-C1) -> rc=0
#
# Pins the `(^|[^a-zA-Z])` left boundary. Without it, "MR3-C1"
# (a commercial part-number shape) would false-match. The lint is
# the structural protector of "do not flag legitimate substrings".

make_fixture_dir
echo "see MR3-C1 part number in the BOM" > "$FIXTURE_DIR/parts.sh"
run_script "$FIXTURE_DIR"
assert_rc "case6 leading-alpha word-boundary" 0
cleanup_fixture_dir

# Case 7: word boundary - trailing alpha (R5-S4abc) -> rc=0
#
# Pins the `([^a-zA-Z0-9]|$)` right boundary. Without it, longer
# identifiers containing the R<n>-<class><n> shape as a prefix would
# false-match.

make_fixture_dir
echo "internal hash R5-S4abc1234 is opaque" > "$FIXTURE_DIR/hash.sh"
run_script "$FIXTURE_DIR"
assert_rc "case7 trailing-alpha word-boundary" 0
cleanup_fixture_dir

# Case 8: README.md excluded -> rc=0
#
# Pins --exclude=README.md. Historical change-log entries reference
# R-numbers; new entries should still avoid them but the lint
# tolerates the existing ones.

make_fixture_dir
echo "Changelog entry: fixed R7-C1 laundering" > "$FIXTURE_DIR/README.md"
run_script "$FIXTURE_DIR"
assert_rc "case8 README excluded rc" 0
cleanup_fixture_dir

# Case 9: .pr-review-cache/ excluded -> rc=0
#
# Pins --exclude-dir=.pr-review-cache. The cache directory is
# gitignored but the lint excludes it for defense in depth.

make_fixture_dir
mkdir -p "$FIXTURE_DIR/.pr-review-cache"
echo "cached review mentions R7-C1, R8-I1" > "$FIXTURE_DIR/.pr-review-cache/pr-16.json"
run_script "$FIXTURE_DIR"
assert_rc "case9 cache-dir excluded rc" 0
cleanup_fixture_dir

# Case 10: R8-I1 regression pin - match-found + grep emits stderr
#
# The original inline lint at .github/workflows/validate.yml had a
# `case "$grep_rc" in 0)` arm that printed the matches and exited
# without ever `cat`-ing the grep_err tempfile. The EXIT trap then
# `rm -f`-ed it, silently dropping any grep stderr that accompanied
# the match (e.g. permission-denied on a sibling unreadable file).
# Same bug-class as R7-I1, applied to a sibling code path.
#
# Trigger: a PATH-injected fake grep that always emits both a match
# on stdout AND a warning on stderr, then exits 0. The real grep
# behavior (BSD/GNU both promote rc=2 when any error occurs) makes
# the natural trigger hard to reproduce, so we use a fake to pin
# the code path structurally. Reverting R8-I1's fix (removing the
# `cat "$grep_err"` from the rc=0 arm) makes this test fail.

make_fixture_dir
FAKE_GREP_DIR=$(mktemp -d)
cat > "$FAKE_GREP_DIR/grep" <<'FAKE'
#!/bin/bash
# Fake grep for R8-I1 test only. Always emits a synthetic match and a
# synthetic stderr warning, then exits 0.
echo "fake-match:1:R7-C1 simulated"
echo "fake-grep: warning: simulated unreadable sibling" >&2
exit 0
FAKE
chmod +x "$FAKE_GREP_DIR/grep"
run_script_with_path "$FAKE_GREP_DIR" "$FIXTURE_DIR"
# Expect rc=1 (match-found path) AND the fake grep's stderr message
# surfaced via STDERR. Without the R8-I1 fix, STDERR would be empty
# (grep's stderr swallowed by the EXIT trap's rm).
assert_rc "case10 R8-I1 match+stderr rc" 1
assert_stderr_contains "case10 R8-I1 stderr surfaced" "fake-grep: warning: simulated unreadable sibling"
rm -rf "$FAKE_GREP_DIR"
cleanup_fixture_dir

# Case 11: script self-exclusion pin.
#
# The lint passes --exclude=check-pr-round-identifiers.sh so its own
# header comments — which contain literal R-number example strings
# (e.g. R7-C1) used to document the regex — do not cause the lint to
# self-fail on CI. That --exclude flag is load-bearing; removing it
# would break every CI run on this repo, but no prior test exercised
# it. Pin by basename: any file with the basename
# check-pr-round-identifiers.sh containing an R-number string must be
# skipped, regardless of where it lives in the scan tree. Reverting
# the --exclude=check-pr-round-identifiers.sh flag makes this case
# fail with the planted "R7-C1" echoed. The success-message assertion
# also guards against vacuous success: a regression that silently
# scanned zero files (e.g. the path-array logic dropping user-
# supplied args) would otherwise let this case pass with rc=0 +
# empty stdout — false-clean.

make_fixture_dir
mkdir -p "$FIXTURE_DIR/scripts"
echo "# header references R7-C1 as a regex example" \
  > "$FIXTURE_DIR/scripts/check-pr-round-identifiers.sh"
run_script "$FIXTURE_DIR/scripts"
assert_rc "case11 script self-exclusion holds" 0
assert_stdout_contains "case11 success message" "No PR-round identifiers"
cleanup_fixture_dir

# Case 12: test-file self-exclusion pin.
#
# Symmetric to case 11: the lint passes
# --exclude=check-pr-round-identifiers-test.sh so the test file's
# own fixture content (literal R-numbers in headers, assertion
# labels, and fixture body strings) does not cause the lint to
# self-fail. Reverting the --exclude=check-pr-round-identifiers-
# test.sh flag makes this case fail with the planted "r7-c1"
# echoed. Each --exclude flag is pinned independently so the two
# cases fail in isolation, which tells a future maintainer exactly
# which flag they regressed.

make_fixture_dir
mkdir -p "$FIXTURE_DIR/tests"
echo "# coverage map says case4 lowercase r7-c1" \
  > "$FIXTURE_DIR/tests/check-pr-round-identifiers-test.sh"
run_script "$FIXTURE_DIR/tests"
assert_rc "case12 test self-exclusion holds" 0
assert_stdout_contains "case12 success message" "No PR-round identifiers"
cleanup_fixture_dir

# Case 13: default-args invocation at repo root.
#
# All cases above pass an explicit fixture-dir positional argument.
# The actual CI invocation (per .github/workflows/validate.yml) runs
# the lint with NO positional args at repo root, scanning the
# script's hard-coded default-path array. The two byte-equal script
# copies (scripts/ and plugins/pr-review-toolkit/scripts/) are
# protected by basename-match --exclude= flags; if anyone ever
# renamed one copy to disambiguate, the basename-match self-
# exclusion would silently break and the regression would only
# surface at CI run time, not in any local test.
#
# This case pins the end-to-end CI contract by invoking the script
# with no args from ROOT_DIR via the run_script_in_dir helper.
#
# Design Decision: case 13 deliberately runs against the live
# working tree (ROOT_DIR) rather than a synthetic fixture root.
# Coupling case 13 to the live tree is intentional — its purpose
# is to verify the same default-path invocation CI uses. If an
# accidental PR-round identifier ever lands in committed source,
# case 13 SHOULD fail locally; that is the correct signal, not a
# conflation with "lint regressed". Switching to a synthetic root
# would defeat the test by no longer exercising the default-path
# array against real content. The success-message + empty-stderr
# assertions together pin both the rc=0 (clean) branch AND the
# absence of any stderr surfacing from the script, so a regression
# that scans nothing or emits unexpected diagnostics will still
# fail loudly.

run_script_in_dir "$ROOT_DIR"
assert_rc "case13 default-args at repo root rc" 0
assert_stdout_contains "case13 default-args success message" "No PR-round identifiers"
assert_stderr_empty "case13 default-args clean stderr"

echo "check-pr-round-identifiers tests passed"
