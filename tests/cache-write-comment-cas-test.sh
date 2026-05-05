#!/bin/bash
# Tests for the --expected-content-hash (CAS) feature of cache-write-comment.sh
# and the producer-side multi-metadata-block sanity check.
#
# Coverage:
#   1. CAS mismatch -> exit 4 and cache is unchanged
#   2. CAS match    -> exit 0 and cache is updated to new content's hash
#   3. CAS hash provided but cache file absent -> exit 4 (current contract)
#   4. Legacy passthrough (no --expected-content-hash) -> exit 0
#   5. Parser validation rejects bad --expected-content-hash inputs -> exit 2
#   6. Multi-metadata-block sanity check: 0 markers -> exit 2,
#      exactly 1 marker -> exit 0, 2 markers -> exit 2.
#
# Runs entirely inside a tempdir (CWD = tempdir) using PR #99999 to avoid
# colliding with real cache files. Exercises --local-only / --stdin so no
# network or `gh` access is required.
#
# Note: every content string passed to the producer must contain exactly
# one '<!-- pr-review-metadata' marker to satisfy the producer-side sanity
# check (case 6 covers the rejection paths). The MARKER constant below is
# prepended to test contents that would otherwise be markerless.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/cache-write-comment.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: script under test not found or not executable: $SCRIPT" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

PR=99999
CACHE_DIR=".pr-review-cache"
CACHE_FILE="$CACHE_DIR/pr-${PR}.json"

# Producer-side check requires exactly one '<!-- pr-review-metadata' marker.
# Prepend MARKER + newline to any test content that needs to pass the check.
MARKER='<!-- pr-review-metadata -->'

# Helper: assert two strings match, fail with a labelled message otherwise.
assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL [$label]: expected='$expected' actual='$actual'" >&2
    exit 1
  fi
}

# Helper: compute "sha256:<64hex>" for the given content (matching the script).
compute_hash() {
  local content="$1"
  echo "sha256:$(printf '%s' "$content" | shasum -a 256 | cut -d' ' -f1)"
}

# Helper: seed cache file with a given content + hash.
seed_cache() {
  local content="$1"
  local hash
  hash="$(compute_hash "$content")"
  mkdir -p "$CACHE_DIR"
  jq -n \
    --arg schema_version "1.0" \
    --argjson pr_number "$PR" \
    --argjson comment_id 0 \
    --arg cached_at "2026-01-01T00:00:00Z" \
    --arg pr_state "OPEN" \
    --arg branch "test-branch" \
    --arg base "main" \
    --arg content "$content" \
    --arg content_hash "$hash" \
    '{
      schema_version: $schema_version,
      pr_number: $pr_number,
      source_comment_id: $comment_id,
      cached_at: $cached_at,
      pr_state: $pr_state,
      branch: $branch,
      base: $base,
      content: $content,
      content_hash: $content_hash
    }' > "$CACHE_FILE"
}

# --- Case 1: CAS mismatch -> exit 4, cache unchanged ----------------------
INITIAL_CONTENT="${MARKER}
initial content for case 1"
seed_cache "$INITIAL_CONTENT"
HASH_BEFORE=$(jq -r '.content_hash' "$CACHE_FILE")
BAD_HASH="sha256:0000000000000000000000000000000000000000000000000000000000000000"

set +e
printf '%s\nnew content\n' "$MARKER" | "$SCRIPT" --stdin "$PR" --local-only --expected-content-hash "$BAD_HASH" \
  >/dev/null 2>"$WORKDIR/case1.err"
status=$?
set -e

assert_eq "case1 exit" "4" "$status"
HASH_AFTER=$(jq -r '.content_hash' "$CACHE_FILE")
assert_eq "case1 cache.content_hash unchanged" "$HASH_BEFORE" "$HASH_AFTER"
echo "PASS [case1] CAS mismatch exits 4 and leaves cache unchanged"

# --- Case 2: CAS match -> exit 0, cache updated ---------------------------
# Cache still holds INITIAL_CONTENT from case 1; read its current hash.
EXPECTED_HASH=$(jq -r '.content_hash' "$CACHE_FILE")
NEW_CONTENT="${MARKER}
updated content for case 2"
EXPECTED_NEW_HASH="$(compute_hash "$NEW_CONTENT")"

set +e
printf '%s' "$NEW_CONTENT" | "$SCRIPT" --stdin "$PR" --local-only --expected-content-hash "$EXPECTED_HASH" \
  >/dev/null 2>"$WORKDIR/case2.err"
status=$?
set -e

assert_eq "case2 exit" "0" "$status"
HASH_NOW=$(jq -r '.content_hash' "$CACHE_FILE")
assert_eq "case2 cache.content_hash updated" "$EXPECTED_NEW_HASH" "$HASH_NOW"
CONTENT_NOW=$(jq -r '.content' "$CACHE_FILE")
assert_eq "case2 cache.content updated" "$NEW_CONTENT" "$CONTENT_NOW"
echo "PASS [case2] CAS match exits 0 and cache reflects new content"

# --- Case 3: cache file absent + --expected-content-hash -> exit 4 --------
rm -f "$CACHE_FILE"
VALID_FORMAT_HASH="sha256:1111111111111111111111111111111111111111111111111111111111111111"

set +e
printf '%s\nany content\n' "$MARKER" | "$SCRIPT" --stdin "$PR" --local-only --expected-content-hash "$VALID_FORMAT_HASH" \
  >/dev/null 2>"$WORKDIR/case3.err"
status=$?
set -e

assert_eq "case3 exit (cache absent + CAS) -> 4" "4" "$status"
if [ -f "$CACHE_FILE" ]; then
  echo "FAIL [case3]: cache file should not have been created on CAS mismatch" >&2
  exit 1
fi
echo "PASS [case3] CAS with absent cache file exits 4 and creates no cache"

# --- Case 4: legacy passthrough (no CAS flag) -> exit 0 -------------------
# 4a) cache absent: write should succeed and create the cache file.
[ ! -e "$CACHE_FILE" ] || rm -f "$CACHE_FILE"
LEGACY_CONTENT_A="${MARKER}
legacy content from-empty"

set +e
printf '%s' "$LEGACY_CONTENT_A" | "$SCRIPT" --stdin "$PR" --local-only \
  >/dev/null 2>"$WORKDIR/case4a.err"
status=$?
set -e

assert_eq "case4a exit (no CAS, no cache)" "0" "$status"
if [ ! -f "$CACHE_FILE" ]; then
  echo "FAIL [case4a]: expected cache file to be created" >&2
  exit 1
fi
EXPECTED_LEGACY_A_HASH="$(compute_hash "$LEGACY_CONTENT_A")"
HASH_4A=$(jq -r '.content_hash' "$CACHE_FILE")
assert_eq "case4a cache.content_hash" "$EXPECTED_LEGACY_A_HASH" "$HASH_4A"

# 4b) cache present: write should still succeed and overwrite the cache.
LEGACY_CONTENT_B="${MARKER}
legacy content overwriting existing"
set +e
printf '%s' "$LEGACY_CONTENT_B" | "$SCRIPT" --stdin "$PR" --local-only \
  >/dev/null 2>"$WORKDIR/case4b.err"
status=$?
set -e

assert_eq "case4b exit (no CAS, cache present)" "0" "$status"
EXPECTED_LEGACY_B_HASH="$(compute_hash "$LEGACY_CONTENT_B")"
HASH_4B=$(jq -r '.content_hash' "$CACHE_FILE")
assert_eq "case4b cache.content_hash" "$EXPECTED_LEGACY_B_HASH" "$HASH_4B"
echo "PASS [case4] legacy passthrough exits 0 in both empty- and existing-cache states"

# --- Case 5: parser validation rejects bad --expected-content-hash --------
# All five sub-cases must exit 2 from the parser/validator before any write.
# Pre-seed the cache so we can also assert it is NOT modified.
seed_cache "case5 sentinel content"
SENTINEL_HASH=$(jq -r '.content_hash' "$CACHE_FILE")

run_case5() {
  local label="$1"
  shift
  set +e
  echo "irrelevant" | "$SCRIPT" "$@" >/dev/null 2>"$WORKDIR/case5_${label}.err"
  local status=$?
  set -e
  assert_eq "case5/$label exit" "2" "$status"
  local hash_now
  hash_now=$(jq -r '.content_hash' "$CACHE_FILE")
  assert_eq "case5/$label cache untouched" "$SENTINEL_HASH" "$hash_now"
}

# 5a) flag with no following arg (must be the last token).
run_case5 "missing-arg" --stdin "$PR" --local-only --expected-content-hash

# 5b) --expected-content-hash= (empty after equals).
run_case5 "equals-empty" --stdin "$PR" --local-only --expected-content-hash=

# 5c) space form with empty value.
run_case5 "space-empty" --stdin "$PR" --local-only --expected-content-hash ""

# 5d) too short (fails 64-hex regex).
run_case5 "too-short" --stdin "$PR" --local-only --expected-content-hash sha256:abc

# 5e) wrong algorithm prefix.
run_case5 "wrong-prefix" --stdin "$PR" --local-only --expected-content-hash \
  "invalidprefix:0000000000000000000000000000000000000000000000000000000000000000"

echo "PASS [case5] parser validation rejects all 5 bad inputs with exit 2"

# --- Case 6: producer-side multi-metadata-block sanity check ---------------
# Reset state: clear cache so case6 is independent of case5's seed.
rm -f "$CACHE_FILE"

# 6a) 0 markers -> exit 2 with "does not contain ... marker"
set +e
printf 'no marker here\n' | "$SCRIPT" --stdin "$PR" --local-only \
  >/dev/null 2>"$WORKDIR/case6a.err"
status=$?
set -e
assert_eq "case6a exit (0 markers)" "2" "$status"
if ! grep -q "does not contain '<!-- pr-review-metadata' marker" "$WORKDIR/case6a.err"; then
  echo "FAIL [case6a]: expected 'does not contain ... marker' error, got:" >&2
  cat "$WORKDIR/case6a.err" >&2
  exit 1
fi
if [ -f "$CACHE_FILE" ]; then
  echo "FAIL [case6a]: cache file should not have been created when content has 0 markers" >&2
  exit 1
fi
echo "PASS [case6a] 0 markers -> exit 2, cache untouched"

# 6b) exactly 1 marker -> exit 0 (happy path)
CASE6B_CONTENT="${MARKER}
case 6b body line"
set +e
printf '%s' "$CASE6B_CONTENT" | "$SCRIPT" --stdin "$PR" --local-only \
  >/dev/null 2>"$WORKDIR/case6b.err"
status=$?
set -e
assert_eq "case6b exit (1 marker)" "0" "$status"
if [ ! -f "$CACHE_FILE" ]; then
  echo "FAIL [case6b]: cache file should have been created" >&2
  exit 1
fi
EXPECTED_6B_HASH="$(compute_hash "$CASE6B_CONTENT")"
HASH_6B=$(jq -r '.content_hash' "$CACHE_FILE")
assert_eq "case6b cache.content_hash" "$EXPECTED_6B_HASH" "$HASH_6B"
echo "PASS [case6b] exactly 1 marker -> exit 0, cache written"

# 6c) 2 markers -> exit 2 with "contains 2 markers" (cache from 6b is preserved)
HASH_BEFORE_6C=$(jq -r '.content_hash' "$CACHE_FILE")
CASE6C_CONTENT="${MARKER}
first block body
${MARKER}
second block body"
set +e
printf '%s' "$CASE6C_CONTENT" | "$SCRIPT" --stdin "$PR" --local-only \
  >/dev/null 2>"$WORKDIR/case6c.err"
status=$?
set -e
assert_eq "case6c exit (2 markers)" "2" "$status"
if ! grep -q "contains 2 '<!-- pr-review-metadata' markers" "$WORKDIR/case6c.err"; then
  echo "FAIL [case6c]: expected 'contains 2 markers' error, got:" >&2
  cat "$WORKDIR/case6c.err" >&2
  exit 1
fi
HASH_AFTER_6C=$(jq -r '.content_hash' "$CACHE_FILE")
assert_eq "case6c cache.content_hash unchanged" "$HASH_BEFORE_6C" "$HASH_AFTER_6C"
echo "PASS [case6c] 2 markers -> exit 2, cache untouched"

# --- Case 7: post-sync cache repair must not truncate the cache -----------
# Regression test for the CF-4 bug: when find-review-comment.sh prints
# multi-line / non-numeric output (originally caused by a stray 2>&1 mixing
# stderr "Using cached comment ID: ..." into stdout), the post-sync repair
# step must reject the bogus value and refuse to truncate the cache file.
#
# Strategy: build an isolated "fake scripts/" tempdir containing
#   - a copy of cache-write-comment.sh (the script under test),
#   - a copy of lib/common.sh (a dependency),
#   - stub find-review-comment.sh that emits the bug pattern,
#   - stub upsert-review-comment.sh that "succeeds" without touching GitHub.
# Then run the copied cache-write-comment.sh from that fake dir so its
# computed SCRIPT_DIR resolves to the stubs.
SRC_SCRIPTS_DIR="$(dirname "$SCRIPT")"
FAKE_SCRIPTS_DIR="$WORKDIR/fake-scripts"
mkdir -p "$FAKE_SCRIPTS_DIR/lib"
cp "$SRC_SCRIPTS_DIR/cache-write-comment.sh" "$FAKE_SCRIPTS_DIR/cache-write-comment.sh"
cp "$SRC_SCRIPTS_DIR/lib/common.sh" "$FAKE_SCRIPTS_DIR/lib/common.sh"
chmod +x "$FAKE_SCRIPTS_DIR/cache-write-comment.sh"

# Stub upsert-review-comment.sh: pretend the GitHub upsert succeeded by
# printing a fake comment URL on stdout and exiting 0. Drains stdin so the
# producer's `echo "$CONTENT" | upsert ...` does not SIGPIPE.
cat > "$FAKE_SCRIPTS_DIR/upsert-review-comment.sh" <<'STUB'
#!/bin/bash
cat >/dev/null
echo "https://github.com/example/repo/issues/0#issuecomment-999"
exit 0
STUB
chmod +x "$FAKE_SCRIPTS_DIR/upsert-review-comment.sh"

# Stub find-review-comment.sh: emit the exact bug pattern — the legacy
# stderr info line concatenated with the numeric ID, both on stdout. With
# the fix (no 2>&1 + strict numeric validation), find_output captures only
# the second line via the normal find script path; here we deliberately
# simulate the worst case where stdout itself is multi-line garbage to
# prove the producer's regex rejects it.
cat > "$FAKE_SCRIPTS_DIR/find-review-comment.sh" <<'STUB'
#!/bin/bash
printf 'Using cached comment ID: 999\n999\n'
exit 0
STUB
chmod +x "$FAKE_SCRIPTS_DIR/find-review-comment.sh"

# Speed up the test: shrink retry budget + interval so we don't sleep ~9s.
# (MAX_RETRIES and RETRY_INTERVAL are set near the top of the script.)
sed -i.bak \
  -e 's/^MAX_RETRIES=.*/MAX_RETRIES=1/' \
  -e 's/^RETRY_INTERVAL=.*/RETRY_INTERVAL=0/' \
  "$FAKE_SCRIPTS_DIR/cache-write-comment.sh"
rm -f "$FAKE_SCRIPTS_DIR/cache-write-comment.sh.bak"

# Seed a non-empty cache so we can compare its size before/after.
rm -f "$CACHE_FILE"
CASE7_CONTENT="${MARKER}
case7 cache content that must survive a failed post-sync repair"
seed_cache "$CASE7_CONTENT"
SIZE_BEFORE=$(wc -c < "$CACHE_FILE" | tr -d ' ')
HASH_BEFORE_7=$(jq -r '.content_hash' "$CACHE_FILE")
if [ "$SIZE_BEFORE" = "0" ]; then
  echo "FAIL [case7 setup]: seeded cache should not be 0 bytes" >&2
  exit 1
fi

# Invoke the *copied* script (not $SCRIPT) so SCRIPT_DIR points at the
# stubs. Run without --local-only so sync_to_github() actually executes.
# Keep --expected-content-hash off; CONTENT matches the seeded cache so
# the local-cache write succeeds and the run reaches the GitHub sync path.
set +e
printf '%s' "$CASE7_CONTENT" | "$FAKE_SCRIPTS_DIR/cache-write-comment.sh" --stdin "$PR" \
  >"$WORKDIR/case7.out" 2>"$WORKDIR/case7.err"
status=$?
set -e

# The producer should fall through to the stale-flag path: GitHub upsert
# "succeeded" but the post-sync ID lookup returned non-numeric output and
# was rejected. Documented exit code for that branch is 1.
assert_eq "case7 exit (post-sync repair rejected)" "1" "$status"

# CRITICAL ASSERTION: the cache file must not have been truncated.
if [ ! -s "$CACHE_FILE" ]; then
  echo "FAIL [case7]: cache file was truncated to 0 bytes (the regression!)" >&2
  echo "  stderr:" >&2
  sed 's/^/    /' "$WORKDIR/case7.err" >&2
  exit 1
fi

SIZE_AFTER=$(wc -c < "$CACHE_FILE" | tr -d ' ')
# The cache may have grown by a few bytes if the stale_source_id flag was
# added; it must NEVER have shrunk and must still parse as JSON with the
# original content_hash and content intact.
if [ "$SIZE_AFTER" -lt "$SIZE_BEFORE" ]; then
  echo "FAIL [case7]: cache size shrank from $SIZE_BEFORE to $SIZE_AFTER bytes" >&2
  exit 1
fi

if ! jq -e . "$CACHE_FILE" >/dev/null 2>&1; then
  echo "FAIL [case7]: cache file is no longer valid JSON" >&2
  cat "$CACHE_FILE" >&2
  exit 1
fi

HASH_AFTER_7=$(jq -r '.content_hash' "$CACHE_FILE")
assert_eq "case7 cache.content_hash preserved" "$HASH_BEFORE_7" "$HASH_AFTER_7"
CONTENT_AFTER_7=$(jq -r '.content' "$CACHE_FILE")
assert_eq "case7 cache.content preserved" "$CASE7_CONTENT" "$CONTENT_AFTER_7"

# Producer should have set the stale-flag escape hatch since the repair
# could not be completed cleanly.
STALE_FLAG=$(jq -r '.stale_source_id // false' "$CACHE_FILE")
assert_eq "case7 cache.stale_source_id" "true" "$STALE_FLAG"

echo "PASS [case7] post-sync repair on multi-line lookup output preserves cache"

echo
echo "All cache-write-comment CAS tests passed."
