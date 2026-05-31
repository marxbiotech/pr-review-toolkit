#!/bin/bash
# Tests for scripts/check-fix-worker-scope.sh
#
# The scope-check script is the structural escape valve for the R1-R4
# recurring fix-introduces-regression pattern in pr-review-resolver step 9.
# Each test case pins a specific class of bug the previous prose form
# had, so that future "let's simplify the pipeline" attempts will fail
# the test loop instead of silently regressing the resolver's safety net.
#
# Coverage (with the PR review round that surfaced each case):
#   1. Empty owned set + clean tree            -> exit 0  (baseline)
#   2. Empty owned set + 1 modified file       -> exit 2  (baseline)
#   3. Tracked modification in OWNED           -> exit 0
#   4. Tracked modification NOT in OWNED       -> exit 2 + path in stderr
#   5. Untracked file in OWNED                 -> exit 0
#   6. Untracked file NOT in OWNED             -> exit 2
#   7. Filename with literal space             -> handled correctly  (R3-C1)
#   8. Filename with literal newline           -> handled correctly  (R4-C1)
#   9. Untracked file inside untracked dir     -> per-file visible   (R4-C2)
#   10. Non-ASCII filename                     -> raw UTF-8, not C-quoted
#   11. Rename, both endpoints in OWNED        -> exit 0             (R3-C4)
#   12. Rename, only old endpoint in OWNED     -> exit 2             (R3-C4)
#
# Each case runs inside its own temp git repo so cases are fully isolated.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${SCRIPT_DIR:-$ROOT_DIR/scripts}"
SCRIPT="$SCRIPT_DIR/check-fix-worker-scope.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: script under test not found or not executable: $SCRIPT" >&2
  exit 1
fi

# Helpers

setup_repo() {
  WORKDIR="$(mktemp -d)"
  cd "$WORKDIR"
  git init -q .
  git config user.email test@example.com
  git config user.name "Test"
  # Disable signing so commit succeeds in CI without gpg.
  git config commit.gpgsign false
  # Seed with one commit so HEAD exists for `git diff HEAD`.
  echo "seed" > .gitkeep
  git add .gitkeep
  git commit -q -m seed
}

teardown_repo() {
  cd /
  rm -rf "$WORKDIR"
}

run_script() {
  # Capture stdout, stderr, and exit code separately so assertions can
  # inspect each independently.
  set +e
  STDOUT=$("$SCRIPT" "$@" 2>/tmp/check-fix-worker-scope-test.stderr)
  RC=$?
  STDERR=$(cat /tmp/check-fix-worker-scope-test.stderr)
  set -e
}

assert_rc() {
  local label="$1"
  local expected="$2"
  if [ "$RC" != "$expected" ]; then
    echo "FAIL [$label]: expected exit $expected, got $RC" >&2
    echo "  stdout: $STDOUT" >&2
    echo "  stderr: $STDERR" >&2
    teardown_repo
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
    teardown_repo
    exit 1
  fi
}

assert_stderr_not_contains() {
  local label="$1"
  local needle="$2"
  if [[ "$STDERR" == *"$needle"* ]]; then
    echo "FAIL [$label]: stderr should NOT contain substring" >&2
    echo "  unexpected substring: $needle" >&2
    echo "  actual stderr: $STDERR" >&2
    teardown_repo
    exit 1
  fi
}

# Case 1: empty owned set + clean tree -> exit 0

setup_repo
run_script
assert_rc "case1 empty/clean" 0
teardown_repo

# Case 2: empty owned set + 1 modified file -> exit 2

setup_repo
echo modified >> .gitkeep
run_script
assert_rc "case2 empty/modified" 2
assert_stderr_contains "case2 empty/modified" ".gitkeep"
teardown_repo

# Case 3: tracked modification in OWNED -> exit 0

setup_repo
echo modified >> .gitkeep
run_script ".gitkeep"
assert_rc "case3 tracked-in-owned" 0
teardown_repo

# Case 4: tracked modification NOT in OWNED -> exit 2 + path in stderr

setup_repo
echo "second" > second.txt
git add second.txt
git commit -q -m "add second"
echo modified >> second.txt
run_script "other.txt"
assert_rc "case4 tracked-not-in-owned" 2
assert_stderr_contains "case4 tracked-not-in-owned" "second.txt"
teardown_repo

# Case 5: untracked file in OWNED -> exit 0

setup_repo
echo new > new.txt
run_script "new.txt"
assert_rc "case5 untracked-in-owned" 0
teardown_repo

# Case 6: untracked file NOT in OWNED -> exit 2

setup_repo
echo new > new.txt
run_script ".gitkeep"
assert_rc "case6 untracked-not-in-owned" 2
assert_stderr_contains "case6 untracked-not-in-owned" "new.txt"
teardown_repo

# Case 7: filename with literal space (R3-C1 regression pin)

setup_repo
echo content > "file with space.txt"
run_script "file with space.txt"
assert_rc "case7 space-in-name in-owned" 0
teardown_repo

setup_repo
echo content > "file with space.txt"
run_script "other.txt"
assert_rc "case7b space-in-name not-in-owned" 2
assert_stderr_contains "case7b space-in-name not-in-owned" "file with space.txt"
teardown_repo

# Case 8: filename with literal newline (R4-C1 regression pin)
#
# This is the R4-C1 bug: the previous `tr '\0' '\n' | awk` form
# converted the embedded newline into a record separator, so awk only
# saw "?? file" (3 chars stripped -> "file") and silently dropped the
# rest. With mapfile-d-'' / read -d '', the byte string is preserved
# end-to-end and the associative-array lookup is byte-exact.

setup_repo
# Path includes literal newline bytes between "file", "with", "newlines.txt"
NL_PATH=$'file\nwith\nnewlines.txt'
echo content > "$NL_PATH"
run_script "$NL_PATH"
assert_rc "case8 newline-in-name in-owned" 0
teardown_repo

setup_repo
NL_PATH=$'file\nwith\nnewlines.txt'
echo content > "$NL_PATH"
# Owned set has only the truncated version "file" — the old buggy form
# would have falsely passed this; the correct form must report the full
# newline-containing path as unexpected.
run_script "file"
assert_rc "case8b newline-in-name not-in-owned" 2
# stderr should contain the full path (even if rendered with literal newlines)
assert_stderr_contains "case8b newline-in-name not-in-owned" "newlines.txt"
teardown_repo

# Case 9: untracked file inside untracked directory (R4-C2 regression pin)
#
# This is the R4-C2 bug: without -uall, `git status --porcelain` collapses
# untracked directory contents to a single "dir/" entry. A worker creating
# arbitrary files inside such a directory would bypass the scope check.
# With -uall, files are enumerated per-file and the scope check sees them.

setup_repo
mkdir untracked_dir
echo secret > untracked_dir/SECRET.txt
echo other > untracked_dir/other.txt
# OWNED declares only one file; SECRET.txt should be flagged as unexpected.
run_script "untracked_dir/other.txt"
assert_rc "case9 untracked-dir-collapse" 2
assert_stderr_contains "case9 untracked-dir-collapse" "SECRET.txt"
# Inverse: if both are owned, scope check passes.
teardown_repo

setup_repo
mkdir untracked_dir
echo secret > untracked_dir/SECRET.txt
echo other > untracked_dir/other.txt
run_script "untracked_dir/SECRET.txt" "untracked_dir/other.txt"
assert_rc "case9b untracked-dir-both-owned" 0
teardown_repo

# Case 10: non-ASCII filename (raw UTF-8 via core.quotePath=false)
#
# With default core.quotePath=true, `git diff --name-only` would emit
# C-quoted forms like "T\303\251dious file.txt" for "Tédious file.txt".
# The OWNED set passes raw "Tédious file.txt" so the comparison would
# fail. core.quotePath=false (set in the script) keeps both sides raw.

setup_repo
echo seed > "Tédious file.txt"
git add "Tédious file.txt"
git commit -q -m "add non-ASCII"
echo modified >> "Tédious file.txt"
run_script "Tédious file.txt"
assert_rc "case10 non-ASCII tracked in-owned" 0
teardown_repo

# Case 11: rename (a -> b), both endpoints in OWNED -> exit 0
#
# --no-renames in the script forces a `git mv` to show as deletion of `a`
# + addition of `b`. Callers must include both endpoints in OWNED.

setup_repo
echo content > a.txt
git add a.txt
git commit -q -m "add a"
git mv a.txt b.txt
run_script "a.txt" "b.txt"
assert_rc "case11 rename both-owned" 0
teardown_repo

# Case 12: rename (a -> b), only old endpoint in OWNED -> exit 2

setup_repo
echo content > a.txt
git add a.txt
git commit -q -m "add a"
git mv a.txt b.txt
run_script "a.txt"
assert_rc "case12 rename only-old-owned" 2
assert_stderr_contains "case12 rename only-old-owned" "b.txt"
teardown_repo

rm -f /tmp/check-fix-worker-scope-test.stderr
echo "check-fix-worker-scope tests passed"
