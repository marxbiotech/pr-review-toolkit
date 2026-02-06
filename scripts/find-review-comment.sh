#!/bin/bash
# Find existing PR review comment by metadata marker
# Returns comment_id if found, empty string otherwise
#
# Usage: ./find-review-comment.sh [PR_NUMBER]
# If PR_NUMBER not provided, uses current branch's PR

set -euo pipefail

PR_NUMBER="${1:-}"

# If no PR number provided, try to get from current branch
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$("$SCRIPT_DIR/get-pr-number.sh" || echo "")
fi

if [ -z "$PR_NUMBER" ]; then
  # No PR found, return empty
  exit 0
fi

# Check local cache first — avoids API call and {owner}/{repo} mismatch issues
CACHE_FILE=".pr-review-cache/pr-${PR_NUMBER}.json"
if [ -f "$CACHE_FILE" ]; then
  CACHED_ID=$(jq -r '.source_comment_id // "0"' "$CACHE_FILE")
  if [ "$CACHED_ID" != "0" ] && [ -n "$CACHED_ID" ]; then
    echo "$CACHED_ID"
    exit 0
  fi
fi

# Fallback: find comment containing our metadata marker via API
if ! API_OUTPUT=$(gh api --paginate "/repos/{owner}/{repo}/issues/${PR_NUMBER}/comments" 2>&1); then
  echo "Error: Failed to fetch PR comments: $API_OUTPUT" >&2
  exit 1
fi

# Find all matching comment IDs
COMMENT_IDS=$(echo "$API_OUTPUT" | jq -r '.[] | select(.body | contains("<!-- pr-review-metadata")) | .id')

# Count non-empty lines (handle empty result gracefully)
if [ -n "$COMMENT_IDS" ]; then
  COMMENT_COUNT=$(echo "$COMMENT_IDS" | wc -l | tr -d ' ')
else
  COMMENT_COUNT=0
fi

if [ "$COMMENT_COUNT" -gt 1 ]; then
  echo "Warning: Found $COMMENT_COUNT review comments, using first one" >&2
fi

COMMENT_ID=$(echo "$COMMENT_IDS" | head -1)
echo "${COMMENT_ID:-}"
