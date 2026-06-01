#!/bin/bash
# Tests for scripts/extract-content-hash.sh
#
# Coverage:
#   1. Valid cache with valid hash       -> exit 0, hash on stdout
#   2. Missing cache file                -> triggers cache-sync stub
#   3. Cache present, hash field missing -> triggers cache-sync stub
#   4. Cache present, hash malformed     -> triggers cache-sync stub
#   5. cache-sync stub recovers successfully -> exit 2 (caller retry signal)
#   6. cache-sync stub fails             -> pass-through rc surfaces
#   7. cache-sync stub produces bad hash -> exit 1 (no retry loop)
#
# cache-sync.sh is stubbed via a fake $SCRIPT_DIR so the test doesn't
# require network or `gh`.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR_DEFAULT="$ROOT_DIR/scripts"
# Caller can override SCRIPT_DIR to test the packaged copy in the same way
# the CI runs both trees.
REAL_SCRIPT_DIR="${SCRIPT_DIR:-$SCRIPT_DIR_DEFAULT}"
REAL_SCRIPT="$REAL_SCRIPT_DIR/extract-content-hash.sh"

if [ ! -x "$REAL_SCRIPT" ]; then
  echo "FAIL: script under test not found or not executable: $REAL_SCRIPT" >&2
  exit 1
fi

PR=99998
VALID_HASH='sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

# Build a sibling script tree with the real extract-content-hash.sh and a
# stubbed cache-sync.sh whose behavior we control via $SYNC_MODE.
mkdir -p stub-scripts
cp "$REAL_SCRIPT" stub-scripts/extract-content-hash.sh
chmod +x stub-scripts/extract-content-hash.sh

CACHE_FILE=".pr-review-cache/pr-${PR}.json"

write_valid_cache() {
  mkdir -p .pr-review-cache
  printf '{"content_hash":"%s"}\n' "$VALID_HASH" > "$CACHE_FILE"
}
write_missing_hash_cache() {
  mkdir -p .pr-review-cache
  printf '{"other_field":"value"}\n' > "$CACHE_FILE"
}
write_malformed_hash_cache() {
  mkdir -p .pr-review-cache
  printf '{"content_hash":"not-sha256"}\n' > "$CACHE_FILE"
}
write_cache_sync_stub() {
  # $1: behavior — one of: write-valid, write-malformed, fail
  #
  # IMPORTANT: this heredoc is UNQUOTED (`<<EOF`, not `<<'EOF'`), so
  # variables — including ${1} — are expanded at heredoc-write time
  # using THIS function's $1, NOT at stub-execution time using the
  # generated stub's $1. That's intentional: each test case calls
  # this function with the desired behavior, and the generated stub
  # is a flat single-behavior script (the case-statement is dead
  # except for the matching branch). Readers debugging the stub
  # should NOT assume it dispatches on its runtime argument.
  cat > stub-scripts/cache-sync.sh <<EOF
#!/bin/bash
# Generated stub — single-behavior, dispatch was at heredoc-write time.
case "${1}" in
  write-valid)
    mkdir -p .pr-review-cache
    printf '{"content_hash":"$VALID_HASH"}\n' > "$CACHE_FILE"
    exit 0
    ;;
  write-malformed)
    mkdir -p .pr-review-cache
    printf '{"content_hash":"bad"}\n' > "$CACHE_FILE"
    exit 0
    ;;
  fail)
    echo "stub: cache-sync failed" >&2
    exit 5
    ;;
esac
EOF
  chmod +x stub-scripts/cache-sync.sh
}

run_script() {
  # Per-invocation mktemp stderr capture so concurrent test runs cannot race.
  local stderr_file
  stderr_file=$(mktemp)
  set +e
  STDOUT=$(stub-scripts/extract-content-hash.sh "$PR" 2>"$stderr_file")
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

# Case 1: valid cache + valid hash -> exit 0, hash on stdout
rm -rf .pr-review-cache
write_valid_cache
write_cache_sync_stub write-valid
run_script
assert_rc "case1 valid" 0
assert_stdout_eq "case1 valid" "$VALID_HASH"

# Case 2: missing cache file -> triggers cache-sync stub (which writes valid),
#         then exits 2 to signal caller-retry
rm -rf .pr-review-cache
write_cache_sync_stub write-valid
run_script
assert_rc "case2 missing-cache + recovery valid" 2
assert_stderr_contains "case2 missing-cache + recovery valid" "file missing"

# Case 3: cache present, hash field missing -> triggers recovery
rm -rf .pr-review-cache
write_missing_hash_cache
write_cache_sync_stub write-valid
run_script
assert_rc "case3 missing-hash + recovery valid" 2
assert_stderr_contains "case3 missing-hash + recovery valid" "malformed hash"

# Case 4: cache present, hash malformed -> triggers recovery
rm -rf .pr-review-cache
write_malformed_hash_cache
write_cache_sync_stub write-valid
run_script
assert_rc "case4 malformed-hash + recovery valid" 2
assert_stderr_contains "case4 malformed-hash + recovery valid" "malformed hash"

# Case 5: combined regression — recovery script claims success but
#         produces a malformed hash (e.g. partial network failure).
#         Must exit 1 with a clear "manual intervention" message rather
#         than entering an infinite retry loop.
rm -rf .pr-review-cache
write_missing_hash_cache
write_cache_sync_stub write-malformed
run_script
assert_rc "case5 recovery-produces-bad-hash" 1
assert_stderr_contains "case5 recovery-produces-bad-hash" "did not produce a valid content_hash"
assert_stderr_contains "case5 recovery-produces-bad-hash" "Manual intervention required"

# Case 6: cache-sync stub fails (rc=5) -> rc surfaces, not silently swallowed
rm -rf .pr-review-cache
write_missing_hash_cache
write_cache_sync_stub fail
run_script
assert_rc "case6 recovery-fails" 5
assert_stderr_contains "case6 recovery-fails" "cache-sync.sh rc=5"

# Case 7: missing $1 (empty PR_NUMBER) -> exit 2 with usage error
#
# Pins that the helper rejects an empty PR number explicitly rather
# than silently falling through (where it would attempt to read
# `.pr-review-cache/pr-.json` and produce confusing diagnostics).
empty_stderr=$(mktemp)
set +e
STDOUT=$(stub-scripts/extract-content-hash.sh "" 2>"$empty_stderr")
RC=$?
STDERR=$(cat "$empty_stderr")
set -e
rm -f "$empty_stderr"
if [ "$RC" != 2 ]; then
  echo "FAIL [case7 empty-arg]: expected exit 2, got $RC" >&2
  exit 1
fi
if [[ "$STDERR" != *"PR number required"* ]]; then
  echo "FAIL [case7 empty-arg]: stderr missing 'PR number required'" >&2
  echo "  actual: $STDERR" >&2
  exit 1
fi

echo "extract-content-hash tests passed"
