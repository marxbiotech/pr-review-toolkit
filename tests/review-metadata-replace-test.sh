#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPGRADE="$ROOT_DIR/scripts/review-metadata-upgrade.sh"
REPLACE="$ROOT_DIR/scripts/review-metadata-replace.sh"
FIXTURES="$ROOT_DIR/tests/fixtures"

tmp_metadata=$(mktemp)
tmp_output=$(mktemp)
trap 'rm -f "$tmp_metadata" "$tmp_output"' EXIT

"$UPGRADE" "$FIXTURES/comment-v1_1-multisource.md" --last-writer codex-fix-worker > "$tmp_metadata"
"$REPLACE" "$FIXTURES/comment-v1_1-multisource.md" "$tmp_metadata" > "$tmp_output"

jq_value=$(awk '
  /^<!-- pr-review-metadata/ { in_meta=1; next }
  in_meta && /^-->$/ { in_meta=0; exit }
  in_meta { print }
' "$tmp_output" | jq -r '.last_writer')

if [ "$jq_value" != "codex-fix-worker" ]; then
  echo "Expected replaced last_writer to be codex-fix-worker, got $jq_value" >&2
  exit 1
fi

if ! grep -q '\[Codex\] Existing Codex issue' "$tmp_output"; then
  echo "Expected Codex issue body to be preserved" >&2
  exit 1
fi

if ! grep -q '\*\*Source:\*\* Codex' "$tmp_output"; then
  echo "Expected Codex source line to be preserved" >&2
  exit 1
fi

set +e
"$REPLACE" "$FIXTURES/comment-no-metadata.md" "$tmp_metadata" >/tmp/review-metadata-replace-no-metadata.out 2>/tmp/review-metadata-replace-no-metadata.err
missing_status=$?
"$REPLACE" "$FIXTURES/comment-multi-metadata.md" "$tmp_metadata" >/tmp/review-metadata-replace-multi.out 2>/tmp/review-metadata-replace-multi.err
multi_status=$?
set -e

if [ "$missing_status" -ne 3 ]; then
  echo "Expected missing metadata to exit 3, got $missing_status" >&2
  exit 1
fi

if [ "$multi_status" -ne 4 ]; then
  echo "Expected multiple metadata blocks to exit 4, got $multi_status" >&2
  exit 1
fi

echo "review-metadata-replace tests passed"
