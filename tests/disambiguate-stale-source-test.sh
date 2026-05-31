#!/bin/bash
# Tests for scripts/disambiguate-stale-source.sh
#
# Coverage (R2-I5 / R3-C2 / R4 family — silent misdiagnosis of
# cache-write-comment.sh exit 1):
#   1. Cache present, stale_source_id=true  -> "Post-sync cache repair failed"
#   2. Cache present, stale_source_id=false -> "GitHub sync failed but cache OK"
#   3. Cache present, field missing         -> defaults to false branch
#   4. Cache file absent                    -> clear missing-file diagnostic
#   5. Cache file is invalid JSON           -> clear jq-failed diagnostic
#
# The script always exits 1 (it's invoked from the exit-1 branch of
# callers); the test checks rc=1 and the stderr message for each case.

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
  rm -f /tmp/disambiguate-stale-source-test.stderr
  set +e
  STDOUT=$("$SCRIPT" "$PR" 2>/tmp/disambiguate-stale-source-test.stderr)
  RC=$?
  STDERR=$(cat /tmp/disambiguate-stale-source-test.stderr)
  set -e
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
# Pre-R4 prose form: `STALE=$(jq ... 2>/dev/null)` would emit empty $STALE on
# missing field, and the `[ "$STALE" = "true" ]` test would correctly take
# the false branch. R3-C2 added file-existence + capture-rc; the
# `// false` default in the jq filter still emits "false" for a missing
# field. This case pins that behavior.
rm -rf .pr-review-cache
write_cache '{"content_hash":"sha256:abc"}'
run_script
assert_rc "case3 field-missing" 1
assert_stderr_contains "case3 field-missing" "GitHub sync failed but local cache is up to date"

# Case 4: cache file absent -> clear diagnostic
#
# Before R3-C2, this case silently took the "GitHub sync failed" branch
# (jq -r '...' /missing.json 2>/dev/null emits empty $STALE; the test
# `[ "$STALE" = "true" ]` is false → "sync failed" branch fires →
# recommends `--sync-from-cache` which then fails because no cache).
rm -rf .pr-review-cache
run_script
assert_rc "case4 cache-absent" 1
assert_stderr_contains "case4 cache-absent" "Cache file vanished"
assert_stderr_not_contains "case4 cache-absent" "GitHub sync failed but local cache is up to date"
assert_stderr_not_contains "case4 cache-absent" "Post-sync cache repair failed"

# Case 5: cache file is invalid JSON -> jq fails, clear diagnostic
#
# Before R3-C2, jq's stderr was swallowed via 2>/dev/null and $STALE was
# empty, so the "sync failed" branch fired silently. The R3-C2 fix
# captures jq's rc; this case pins that the failure is visible.
rm -rf .pr-review-cache
write_cache 'not valid json {'
run_script
assert_rc "case5 invalid-json" 1
assert_stderr_contains "case5 invalid-json" "jq failed reading"
assert_stderr_not_contains "case5 invalid-json" "GitHub sync failed but local cache is up to date"
assert_stderr_not_contains "case5 invalid-json" "Post-sync cache repair failed"

echo "disambiguate-stale-source tests passed"
