#!/bin/bash
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
assert_jq "$legacy" '.review_sources.claude.agents_run | join(",")' 'code-reviewer,pr-test-analyzer'
assert_jq "$legacy" '.review_sources.gemini.consumed_comment_ids | join(",")' '111,222'
assert_jq "$legacy" '.review_sources.gemini.last_integrated_at' '2026-05-01T02:00:00Z'
assert_jq "$legacy" '.review_sources.codex.posted_finding_ids | length' '0'

multi=$("$SCRIPT" "$FIXTURES/comment-v1_1-multisource.md" --last-writer codex-fix-worker)
assert_jq "$multi" '.schema_version' '1.1'
assert_jq "$multi" '.created_by' 'codex-review-pass'
assert_jq "$multi" '.last_writer' 'codex-fix-worker'
assert_jq "$multi" '.review_sources.claude.last_reviewed_head' 'abc'
assert_jq "$multi" '.review_sources.gemini.consumed_comment_ids | join(",")' '333'
assert_jq "$multi" '.review_sources.codex.posted_finding_ids | join(",")' 'codex:src/example.ts:fn:bug:abcd'

set +e
"$SCRIPT" "$FIXTURES/comment-no-metadata.md" >/tmp/review-metadata-upgrade-no-metadata.out 2>/tmp/review-metadata-upgrade-no-metadata.err
status=$?
set -e
if [ "$status" -ne 3 ]; then
  echo "Expected missing metadata to exit 3, got $status" >&2
  exit 1
fi

echo "review-metadata-upgrade tests passed"
