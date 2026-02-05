#!/bin/bash
# Force sync local cache with GitHub
# Wrapper around cache-read-comment.sh --force-refresh with detailed output
#
# Usage: ./cache-sync.sh [PR_NUMBER]
#
# Exit codes: 0=success (with or without changes), 1=error, 2=no comment found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR=".pr-review-cache"

PR_NUMBER="${1:-}"

# If no PR number provided, try to get from current branch
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$("$SCRIPT_DIR/get-pr-number.sh" || echo "")
fi

if [ -z "$PR_NUMBER" ]; then
  echo "Error: No PR number found. Ensure you're on a branch with an open PR or provide PR number." >&2
  exit 1
fi

CACHE_FILE="${CACHE_DIR}/pr-${PR_NUMBER}.json"

echo "=== PR Review Cache Sync ===" >&2
echo "PR #$PR_NUMBER" >&2
echo "" >&2

# Check existing cache
OLD_HASH=""
OLD_CACHED_AT=""
if [ -f "$CACHE_FILE" ]; then
  OLD_HASH=$(jq -r '.content_hash // ""' "$CACHE_FILE")
  OLD_CACHED_AT=$(jq -r '.cached_at // ""' "$CACHE_FILE")
  echo "Previous cache: $OLD_CACHED_AT" >&2
  echo "Previous hash: $OLD_HASH" >&2
else
  echo "No existing cache found" >&2
fi

echo "" >&2
echo "Fetching from GitHub..." >&2

# Force refresh - capture output but also let it go to stdout
if ! CONTENT=$("$SCRIPT_DIR/cache-read-comment.sh" "$PR_NUMBER" --force-refresh 2>&1); then
  EXIT_CODE=$?
  echo "$CONTENT" >&2
  exit $EXIT_CODE
fi

# Check new cache
if [ -f "$CACHE_FILE" ]; then
  NEW_HASH=$(jq -r '.content_hash // ""' "$CACHE_FILE")
  NEW_CACHED_AT=$(jq -r '.cached_at // ""' "$CACHE_FILE")

  echo "" >&2
  echo "New cache: $NEW_CACHED_AT" >&2
  echo "New hash: $NEW_HASH" >&2

  if [ -n "$OLD_HASH" ] && [ "$OLD_HASH" != "$NEW_HASH" ]; then
    echo "" >&2
    echo "⚠️  Content changed since last cache!" >&2
  elif [ -n "$OLD_HASH" ]; then
    echo "" >&2
    echo "✓ Content unchanged" >&2
  fi
fi

echo "" >&2
echo "=== Sync complete ===" >&2
