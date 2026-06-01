#!/bin/bash
# Tests for scripts/check-fix-worker-scope.sh
#
# The scope-check script is the structural escape valve for the R1-R4
# recurring fix-introduces-regression pattern in pr-review-resolver step 9.
# Each test case pins a specific class of bug the previous prose form
# had, so that future "let's simplify the pipeline" attempts will fail
# the test loop instead of silently regressing the resolver's safety net.
#
# Coverage:
#   1.  Empty owned set + clean tree            -> exit 0 (baseline)
#   2.  Empty owned set + 1 modified file       -> exit 2 (baseline)
#   3.  Tracked modification in OWNED           -> exit 0
#   4.  Tracked modification NOT in OWNED       -> exit 2 + path in stderr
#   5.  Untracked file in OWNED                 -> exit 0
#   6.  Untracked file NOT in OWNED             -> exit 2
#   7.  Filename with literal space             -> handled correctly
#   8.  Filename with literal newline           -> read -d '' preserves bytes
#                                                 (pre-fix: tr '\0' '\n' truncated)
#   9.  Untracked file inside untracked dir     -> -uall forces per-file enum
#                                                 (pre-fix: dir/ collapsed entry
#                                                  hid all contents)
#   10. Non-ASCII filename                      -> raw UTF-8, not C-quoted
#   11. Rename, both endpoints in OWNED         -> exit 0
#   12. Rename, only old endpoint in OWNED      -> exit 2
#   13. Untracked file with leading space       -> not double-stripped from prefix
#                                                 (pre-fix: `path="${path# }"`
#                                                  stripped a second space, letting
#                                                  workers bypass scope via
#                                                  leading-space filenames)
#   14. Invoked outside a git repository        -> exit non-zero with git stderr
#                                                 (pre-fix: process substitution
#                                                  swallowed git rc, exit 0)
#   15. Rename hides non-owned source (data
#       exfiltration scenario)                  -> --no-renames forces both
#                                                 endpoints visible
#                                                 (pre-fix: cases 11/12 used 1-byte
#                                                  files that didn't trigger
#                                                  rename detection, making the
#                                                  --no-renames flag decorative)
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
  # inspect each independently. Use a per-invocation mktemp file so:
  #   (a) concurrent test runs (e.g. CI matrix running both script
  #       trees in parallel) cannot race on a shared `/tmp/<name>-test.stderr`,
  #   (b) the capture file lives OUTSIDE the test repo's worktree so
  #       it doesn't show up as an untracked file in scope-check tests
  #       (which would break the case 1 "empty owned set + clean tree"
  #       baseline).
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

# Case 7: filename with literal space

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

# Case 8: filename with literal newline (newline-truncation bug pin)
#
# The previous `tr '\0' '\n' | awk` form converted the embedded newline
# into a record separator, so awk only saw "?? file" (3 chars stripped
# -> "file") and silently dropped the rest. With `read -r -d ''`, the
# byte string is preserved end-to-end and the linear-scan lookup is
# byte-exact.

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

# Case 9: untracked file inside untracked directory (untracked-dir collapse bug pin)
#
# Without -uall, `git status --porcelain` collapses untracked directory
# contents to a single "dir/" entry. A worker creating arbitrary files
# inside such a directory would bypass the scope check. With -uall, files
# are enumerated per-file and the scope check sees them.

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

# Case 10: non-ASCII filename
#
# Verifies that a non-ASCII filename round-trips correctly through the
# script. Note: under `-z` mode, `git diff --name-only` already emits
# raw UTF-8 regardless of `core.quotePath` (the flag only affects
# non-`-z` output). The `core.quotePath=false` flag in the script is
# defensive insurance against a future maintainer removing `-z` —
# this test would NOT catch a regression of `core.quotePath=false`
# alone (would need a parallel test without `-z`). What this case
# DOES pin: byte-exact handling of multi-byte UTF-8 sequences through
# the linear-scan comparison.

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

# Case 13: untracked file with leading space in filename — load-bearing.
#
# Pins the "leading-space scope escape" bug: porcelain v1 -z output for an
# untracked file with a leading space in its name is `??  leading.txt\0`
# (3-char prefix + 1 leading space + filename). If the script strips an
# extra leading space after the prefix, a worker can drop ` evil.txt` and
# bypass scope check by declaring `evil.txt` (no leading space) as owned.
# This test FAILS if the script does `path="${path# }"` after the prefix
# strip — verified by hypothetical-revert experiment.

setup_repo
touch ' leading.txt'
run_script ' leading.txt'   # owned set declares the actual leading-space name
assert_rc "case13 leading-space in-owned" 0
teardown_repo

setup_repo
touch ' leading.txt'
run_script 'leading.txt'    # owned set has no leading space; scope escape attempt
assert_rc "case13b leading-space scope-escape" 2
assert_stderr_contains "case13b leading-space scope-escape" "leading.txt"
teardown_repo

# Case 14: scope check invoked outside a git repository — load-bearing.
#
# Pins the "git-failure silently treated as scope OK" bug. Process
# substitution `< <(git ...)` runs git in a subshell whose exit status is
# NOT captured by the parent's `set -euo pipefail`. Without explicit rc
# capture, a not-a-git-repo invocation would silently exit 0, telling
# the resolver "scope OK, proceed" when git never ran.

NOT_A_REPO="$(mktemp -d)"
cd "$NOT_A_REPO"
run_script "owned.txt"
# Expected: non-zero exit and a clear "not a git repository" diagnostic on
# stderr. The exact exit code is the git rc passed through (typically 128).
if [ "$RC" -eq 0 ]; then
  echo "FAIL [case14 not-a-git-repo]: expected non-zero exit, got 0 (git failure silently swallowed)" >&2
  echo "  stderr was: $STDERR" >&2
  cd /
  rm -rf "$NOT_A_REPO"
  exit 1
fi
# Git emits "Not a git repository" (capital N) or "not a git repository"
# (lowercase, in `fatal:` lines) depending on subcommand. We accept either.
if [[ "$STDERR" != *"ot a git repository"* ]]; then
  echo "FAIL [case14 not-a-git-repo]: stderr missing 'ot a git repository' substring" >&2
  echo "  stderr: $STDERR" >&2
  cd /
  rm -rf "$NOT_A_REPO"
  exit 1
fi
cd /
rm -rf "$NOT_A_REPO"

# Case 16: gitignored file written by worker outside OWNED — load-bearing.
#
# Pins the "gitignored scope escape" bug. Without --ignored=traditional
# on git status, gitignored files (e.g. *.log, node_modules/, .env,
# secrets/) created by a fix-worker would be invisible to the scope
# check. A worker could exfiltrate data via a gitignored file with no
# scope-check trace. With --ignored=traditional, gitignored files are
# surfaced as `!! path` records and the script flags them as
# unexpected if they're not in OWNED.

setup_repo
echo '*.log' > .gitignore
git add .gitignore
git commit -q -m "ignore logs"
echo secret > worker.log    # fix-worker writes a gitignored file
run_script ".gitignore"      # OWNED does NOT include worker.log
assert_rc "case16 gitignored scope-escape" 2
assert_stderr_contains "case16 gitignored scope-escape" "worker.log"
teardown_repo

# Case 17: gitignored file IS in OWNED -> exit 0.
#
# Some fix-workers legitimately need to write a gitignored file (e.g.
# a fixture that's gitignored to keep CI quiet). When OWNED declares
# the file explicitly, the scope check should pass.

setup_repo
echo '*.log' > .gitignore
git add .gitignore
git commit -q -m "ignore logs"
echo legit > fixture.log
run_script ".gitignore" "fixture.log"
assert_rc "case17 gitignored in-owned" 0
teardown_repo

# Case 15: rename where the rename target is owned but the source is NOT — load-bearing.
#
# Pins the "rename hides non-owned source" bug. With default rename
# detection, `git diff --name-only HEAD` collapses a `git mv secret.txt
# b.txt` to a single `b.txt` entry. If the worker is allowed to touch
# b.txt but NOT secret.txt, default rename detection lets the worker
# silently rename secret.txt away (data exfiltration / scope escape).
# With --no-renames, the rename appears as deletion of secret.txt +
# addition of b.txt, so the scope check sees secret.txt as unexpected
# and aborts.
#
# Cases 11/12 above are NOT sufficient to pin this — they passed even
# with --no-renames removed because the 1-byte file content was too
# small to trigger git's rename-detection heuristic (similarity index).
# This case uses substantial content (100 lines) to guarantee rename
# detection fires, so removing --no-renames from the script causes
# this case to FAIL with rc=0 instead of the expected rc=2.

setup_repo
seq 1 100 > secret.txt   # 100 lines guarantees rename-detection similarity
git add secret.txt
git commit -q -m "add secret"
git mv secret.txt b.txt  # rename source is secret.txt (not in OWNED), target is b.txt (in OWNED)
run_script "b.txt"                                                # OWNED = {b.txt}
assert_rc "case15 rename hides non-owned source" 2                # without --no-renames: 0 (BYPASS)
assert_stderr_contains "case15 rename hides non-owned source" "secret.txt"
teardown_repo

# Case 18: GIT_TRACE=1 environment must not contaminate scope-check stderr — load-bearing.
#
# Pins the "git stderr-on-success contamination" bug. The script captures
# git output with `> "$TMP" 2>&1`, but git emits trace lines to stderr under
# environment switches like GIT_TRACE=1 / GIT_TRACE_PERFORMANCE / advice.*
# even on successful invocations. Merging stderr into the path-stream file
# makes the path-reader parse trace lines AS paths, producing a diagnostic
# full of "Unexpected files: <git internal traces>". Fail-CLOSED (no scope
# bypass — the traces can't match OWNED), but the diagnostic becomes
# unreadable for developers debugging under common debug envs.
#
# This is the same silent-misdiagnosis class that the jq stderr-separation
# fix closed in extract-content-hash.sh and disambiguate-stale-source.sh.
# Pinned here so a future "2>&1 is simpler" reversion fails CI.

setup_repo
echo modified >> .gitkeep                  # one tracked modification
# Wrap with explicit GIT_TRACE=1 env var. Run via env to isolate from
# whatever the test runner's parent shell has set.
run_script_under_trace() {
  local stderr_file
  stderr_file=$(mktemp)
  set +e
  STDOUT=$(env GIT_TRACE=1 "$SCRIPT" "$@" 2>"$stderr_file")
  RC=$?
  STDERR=$(cat "$stderr_file")
  set -e
  rm -f "$stderr_file"
}
run_script_under_trace ".gitkeep"          # OWNED is exactly the modified file
# Modification is in OWNED so the scope check should exit 0 with NO stderr.
assert_rc "case18 GIT_TRACE clean run" 0
# The stderr must not contain any "trace:" lines from git's internal logging.
if [[ "$STDERR" == *"trace:"* ]]; then
  echo "FAIL [case18 GIT_TRACE clean run]: git trace lines contaminated stderr" >&2
  echo "  stderr was: $STDERR" >&2
  teardown_repo
  exit 1
fi
teardown_repo

echo "check-fix-worker-scope tests passed"
