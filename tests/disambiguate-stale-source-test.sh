#!/bin/bash
# Tests for scripts/disambiguate-stale-source.sh
#
# Coverage (silent-misdiagnosis bug family for cache-write-comment.sh
# exit code 1, which covers two distinct failure modes — GitHub sync
# failed vs post-sync cache repair failed — that earlier prose forms
# routed to the wrong recovery command):
#   1. Cache present, stale_source_id=true  -> "Post-sync cache repair failed"
#   2. Cache present, stale_source_id=false -> "GitHub sync failed but cache OK"
#   3. Cache present, field missing         -> defaults to false branch
#   4. Cache file absent                    -> clear missing-file diagnostic
#   5. Cache file is invalid JSON           -> clear jq-failed diagnostic
#
# The script always exits 1 (it's invoked from the exit-1 branch of
# callers); the test checks rc=1 and the stderr message for each case.
# Cases 4 and 5 are load-bearing: earlier forms using `2>/dev/null` on
# the jq call routed both into the "GitHub sync failed" branch silently.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR_DEFAULT="$ROOT_DIR/scripts"
REAL_SCRIPT_DIR="${SCRIPT_DIR:-$SCRIPT_DIR_DEFAULT}"
SCRIPT="$REAL_SCRIPT_DIR/disambiguate-stale-source.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: script under test not found or not executable: $SCRIPT" >&2
  exit 1
fi

PR=99997

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

CACHE_FILE=".pr-review-cache/pr-${PR}.json"

write_cache() {
  # $1: JSON content
  mkdir -p .pr-review-cache
  printf '%s\n' "$1" > "$CACHE_FILE"
}

run_script() {
  # Per-invocation mktemp stderr capture so concurrent test runs cannot race.
  local stderr_file
  stderr_file=$(mktemp)
  set +e
  STDOUT=$("$SCRIPT" "$PR" 2>"$stderr_file")
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

assert_stderr_not_contains() {
  local label="$1"
  local needle="$2"
  if [[ "$STDERR" == *"$needle"* ]]; then
    echo "FAIL [$label]: stderr should NOT contain substring" >&2
    echo "  unexpected substring: $needle" >&2
    echo "  actual stderr: $STDERR" >&2
    exit 1
  fi
}

# Case 1: stale_source_id=true -> "Post-sync cache repair failed"
rm -rf .pr-review-cache
write_cache '{"content_hash":"sha256:abc","stale_source_id":true}'
run_script
assert_rc "case1 stale=true" 1
assert_stderr_contains "case1 stale=true" "Post-sync cache repair failed"
assert_stderr_not_contains "case1 stale=true" "GitHub sync failed but local cache is up to date"

# Case 2: stale_source_id=false -> "GitHub sync failed but cache OK"
rm -rf .pr-review-cache
write_cache '{"content_hash":"sha256:abc","stale_source_id":false}'
run_script
assert_rc "case2 stale=false" 1
assert_stderr_contains "case2 stale=false" "GitHub sync failed but local cache is up to date"
assert_stderr_not_contains "case2 stale=false" "Post-sync cache repair failed"

# Case 3: stale_source_id field missing -> defaults to false branch
#
# This case pins the `// false` jq default. When `stale_source_id` is
# absent (older cache envelopes that never had the flag set), the script
# must take the "GitHub sync failed" branch (the more common cause when
# the flag is unset). Without this default, a missing field would route
# to the wrong recovery command.
rm -rf .pr-review-cache
write_cache '{"content_hash":"sha256:abc"}'
run_script
assert_rc "case3 field-missing" 1
assert_stderr_contains "case3 field-missing" "GitHub sync failed but local cache is up to date"

# Case 4: cache file absent -> exit 10 (cannot-disambiguate)
#
# Earlier prose forms (before the file-existence precheck was added)
# silently took the "GitHub sync failed" branch: `jq -r '...'
# /missing.json 2>/dev/null` emits empty $STALE; the test `[ "$STALE" =
# "true" ]` is false → "sync failed" branch fires → recommends
# `--sync-from-cache` which then fails because no cache exists. This
# case pins that the missing-file case is now caught explicitly with a
# clear diagnostic AND a distinct exit code (10 = cannot-disambiguate)
# so downstream tooling can branch on "nominal advice ready" (1) vs
# "investigation required" (10).
rm -rf .pr-review-cache
run_script
assert_rc "case4 cache-absent" 10
assert_stderr_contains "case4 cache-absent" "Cache file vanished"
assert_stderr_not_contains "case4 cache-absent" "GitHub sync failed but local cache is up to date"
assert_stderr_not_contains "case4 cache-absent" "Post-sync cache repair failed"

# Case 5: cache file is invalid JSON -> exit 10 (cannot-disambiguate)
#
# Earlier prose forms swallowed jq's stderr via 2>/dev/null and left
# $STALE empty, so the "sync failed" branch fired silently. The current
# script captures jq's rc explicitly AND exits 10 (not 1) so downstream
# tooling can distinguish "nominal advice ready" from "investigation
# required because the cache itself is broken".
rm -rf .pr-review-cache
write_cache 'not valid json {'
run_script
assert_rc "case5 invalid-json" 10
assert_stderr_contains "case5 invalid-json" "jq failed reading"
assert_stderr_not_contains "case5 invalid-json" "GitHub sync failed but local cache is up to date"
assert_stderr_not_contains "case5 invalid-json" "Post-sync cache repair failed"

# Case 6: missing $1 (empty PR_NUMBER) -> exit 1 with usage error
#
# Pins that the helper rejects an empty PR number explicitly. Empty $1
# exits 1 (not 10) because the caller's exit-1 propagation contract
# means even a usage error should keep the explicit-1 flow.
empty_stderr=$(mktemp)
set +e
STDOUT=$("$SCRIPT" "" 2>"$empty_stderr")
RC=$?
STDERR=$(cat "$empty_stderr")
set -e
rm -f "$empty_stderr"
if [ "$RC" != 1 ]; then
  echo "FAIL [case6 empty-arg]: expected exit 1, got $RC" >&2
  exit 1
fi
if [[ "$STDERR" != *"PR number required"* ]]; then
  echo "FAIL [case6 empty-arg]: stderr missing 'PR number required'" >&2
  echo "  actual: $STDERR" >&2
  exit 1
fi

echo "disambiguate-stale-source tests passed"
