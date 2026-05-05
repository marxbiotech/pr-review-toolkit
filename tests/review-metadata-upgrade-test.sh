#!/bin/bash
# Tests for scripts/review-metadata-upgrade.sh
#
# Verifies the 1.0 -> 1.1 metadata upgrade and dual-write contract:
# - schema 1.0 legacy fixture upgrades to 1.1 with correct field migration
#   (gemini_integrated_ids -> review_sources.gemini.consumed_comment_ids,
#    gemini_integration_date -> review_sources.gemini.last_integrated_at,
#    skill -> last_writer mirror).
# - schema 1.1 multisource fixture is preserved and re-upgrade rotates
#   skill to the new last_writer.
# - top-level agents_run is unconditionally mirrored from review_sources.claude.agents_run
#   (Phase-2 dual-write contract), exercised via an inline --stdin v1.1 block
#   whose top-level agents_run is missing.
# - Multiple metadata blocks in input are rejected with exit 4 and empty stdout
#   (symmetric with replace.sh).
# - Missing metadata block exits 3 with empty stdout.
# - Non-object metadata content (null fixture, scalar via --stdin, array via --stdin)
#   is rejected with exit 3, stderr names the actual JSON type, and stdout is empty.
#
# Fixtures used: tests/fixtures/comment-{v1-legacy,v1_1-multisource,multi-metadata,no-metadata,null-metadata}.md
#
# Usage: bash tests/review-metadata-upgrade-test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/review-metadata-upgrade.sh"
FIXTURES="$ROOT_DIR/tests/fixtures"

assert_jq() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual

  actual=$(printf '%s\n' "$json" | jq -r "$filter")
  if [ "$actual" != "$expected" ]; then
    echo "Assertion failed: $filter" >&2
    echo "Expected: $expected" >&2
    echo "Actual:   $actual" >&2
    exit 1
  fi
}

legacy=$("$SCRIPT" "$FIXTURES/comment-v1-legacy.md" --last-writer pr-review-and-document)
assert_jq "$legacy" '.schema_version' '1.1'
assert_jq "$legacy" '.created_by' 'pr-review-and-document'
assert_jq "$legacy" '.last_writer' 'pr-review-and-document'
assert_jq "$legacy" '.skill' 'pr-review-and-document'
assert_jq "$legacy" '.review_sources.claude.agents_run | join(",")' 'code-reviewer,pr-test-analyzer'
assert_jq "$legacy" '.review_sources.gemini.consumed_comment_ids | join(",")' '111,222'
assert_jq "$legacy" '.review_sources.gemini.last_integrated_at' '2026-05-01T02:00:00Z'
assert_jq "$legacy" '.review_sources.codex.posted_finding_ids | length' '0'
# Phase-2 dual-write contract: top-level agents_run must mirror nested.
assert_jq "$legacy" '.agents_run | join(",")' 'code-reviewer,pr-test-analyzer'
assert_jq "$legacy" '(.agents_run == .review_sources.claude.agents_run)' 'true'

# Unconditional-mirror assertion: feed an inline v1.1 metadata block where
# top-level agents_run is missing but nested is populated, then verify the
# upgrade re-establishes the top-level mirror.
mirror_input=$(cat <<'JSON'
<!-- pr-review-metadata
{
  "schema_version": "1.1",
  "created_by": "pr-review-and-document",
  "last_writer": "pr-review-and-document",
  "skill": "pr-review-and-document",
  "review_sources": {
    "claude": {
      "last_reviewed_head": "deadbeef",
      "last_reviewed_at": "2026-05-01T00:30:00Z",
      "agents_run": ["code-reviewer", "pr-test-analyzer"]
    },
    "gemini": {
      "consumed_comment_ids": [],
      "last_integrated_at": null
    },
    "codex": {
      "last_reviewed_head": null,
      "last_reviewed_at": null,
      "posted_finding_ids": []
    }
  }
}
-->

## PR Review
JSON
)
mirror=$(printf '%s\n' "$mirror_input" | "$SCRIPT" --stdin --last-writer pr-review-and-document)
assert_jq "$mirror" '.agents_run | join(",")' 'code-reviewer,pr-test-analyzer'
assert_jq "$mirror" '(.agents_run == .review_sources.claude.agents_run)' 'true'

multi=$("$SCRIPT" "$FIXTURES/comment-v1_1-multisource.md" --last-writer codex-fix-worker)
assert_jq "$multi" '.schema_version' '1.1'
assert_jq "$multi" '.created_by' 'codex-review-pass'
assert_jq "$multi" '.last_writer' 'codex-fix-worker'
assert_jq "$multi" '.skill' 'codex-fix-worker'
assert_jq "$multi" '.review_sources.claude.last_reviewed_head' 'abc'
assert_jq "$multi" '.review_sources.gemini.consumed_comment_ids | join(",")' '333'
assert_jq "$multi" '.review_sources.codex.posted_finding_ids | join(",")' 'codex:src/example.ts:fn:bug:abcd'

# Re-upgrade an already-1.1 metadata block with a different --last-writer to
# verify skill rotates with last_writer instead of freezing on first upgrade.
reupgrade=$("$SCRIPT" "$FIXTURES/comment-v1_1-multisource.md" --last-writer pr-review-resolver)
assert_jq "$reupgrade" '.last_writer' 'pr-review-resolver'
assert_jq "$reupgrade" '.skill' 'pr-review-resolver'

set +e
"$SCRIPT" "$FIXTURES/comment-no-metadata.md" >/tmp/review-metadata-upgrade-no-metadata.out 2>/tmp/review-metadata-upgrade-no-metadata.err
status=$?
set -e
if [ "$status" -ne 3 ]; then
  echo "Expected missing metadata to exit 3, got $status" >&2
  exit 1
fi

set +e
"$SCRIPT" "$FIXTURES/comment-multi-metadata.md" >/tmp/review-metadata-upgrade-multi.out 2>/tmp/review-metadata-upgrade-multi.err
multi_status=$?
set -e
if [ "$multi_status" -ne 4 ]; then
  echo "Expected multiple metadata blocks to exit 4, got $multi_status" >&2
  exit 1
fi
if ! grep -q 'multiple pr-review metadata blocks found' /tmp/review-metadata-upgrade-multi.err; then
  echo "Expected stderr to mention 'multiple pr-review metadata blocks found'" >&2
  cat /tmp/review-metadata-upgrade-multi.err >&2
  exit 1
fi
if [ -s /tmp/review-metadata-upgrade-multi.out ]; then
  echo "FAIL: expected empty stdout on multi-metadata exit 4, got $(wc -c < /tmp/review-metadata-upgrade-multi.out) bytes" >&2
  exit 1
fi

# Non-object JSON metadata (null) must be rejected with exit 3 and a clear
# stderr message; stdout must be empty so callers cannot consume a fabricated
# upgrade payload.
set +e
"$SCRIPT" "$FIXTURES/comment-null-metadata.md" >/tmp/review-metadata-upgrade-null.out 2>/tmp/review-metadata-upgrade-null.err
null_status=$?
set -e
if [ "$null_status" -ne 3 ]; then
  echo "Expected null metadata to exit 3, got $null_status" >&2
  exit 1
fi
if ! grep -q 'must be a JSON object' /tmp/review-metadata-upgrade-null.err; then
  echo "Expected stderr to mention 'must be a JSON object'" >&2
  cat /tmp/review-metadata-upgrade-null.err >&2
  exit 1
fi
if ! grep -q 'got null' /tmp/review-metadata-upgrade-null.err; then
  echo "Expected stderr to mention 'got null'" >&2
  cat /tmp/review-metadata-upgrade-null.err >&2
  exit 1
fi
if [ -s /tmp/review-metadata-upgrade-null.out ]; then
  echo "FAIL: expected empty stdout on null-metadata exit 3, got $(wc -c < /tmp/review-metadata-upgrade-null.out) bytes" >&2
  exit 1
fi

# Scalar and array metadata must also be rejected via --stdin to avoid
# adding more on-disk fixtures.
scalar_input=$(cat <<'MARKDOWN'
<!-- pr-review-metadata
"string"
-->

## PR Review
MARKDOWN
)
set +e
printf '%s\n' "$scalar_input" | "$SCRIPT" --stdin >/tmp/review-metadata-upgrade-scalar.out 2>/tmp/review-metadata-upgrade-scalar.err
scalar_status=$?
set -e
if [ "$scalar_status" -ne 3 ]; then
  echo "Expected scalar metadata to exit 3, got $scalar_status" >&2
  exit 1
fi
if ! grep -q 'got string' /tmp/review-metadata-upgrade-scalar.err; then
  echo "Expected stderr to mention 'got string'" >&2
  cat /tmp/review-metadata-upgrade-scalar.err >&2
  exit 1
fi
if [ -s /tmp/review-metadata-upgrade-scalar.out ]; then
  echo "FAIL: expected empty stdout on scalar-metadata exit 3, got $(wc -c < /tmp/review-metadata-upgrade-scalar.out) bytes" >&2
  exit 1
fi

array_input=$(cat <<'MARKDOWN'
<!-- pr-review-metadata
[1,2,3]
-->

## PR Review
MARKDOWN
)
set +e
printf '%s\n' "$array_input" | "$SCRIPT" --stdin >/tmp/review-metadata-upgrade-array.out 2>/tmp/review-metadata-upgrade-array.err
array_status=$?
set -e
if [ "$array_status" -ne 3 ]; then
  echo "Expected array metadata to exit 3, got $array_status" >&2
  exit 1
fi
if ! grep -q 'got array' /tmp/review-metadata-upgrade-array.err; then
  echo "Expected stderr to mention 'got array'" >&2
  cat /tmp/review-metadata-upgrade-array.err >&2
  exit 1
fi
if [ -s /tmp/review-metadata-upgrade-array.out ]; then
  echo "FAIL: expected empty stdout on array-metadata exit 3, got $(wc -c < /tmp/review-metadata-upgrade-array.out) bytes" >&2
  exit 1
fi

echo "review-metadata-upgrade tests passed"
