#!/bin/bash
# Find existing PR review comment — checks local cache first, falls back to API
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
# (gh's {owner}/{repo} resolves from git remote, which may differ from the PR's
# target repo when working from a fork or after a repo transfer)
CACHE_FILE=".pr-review-cache/pr-${PR_NUMBER}.json"
if [ -f "$CACHE_FILE" ]; then
  # source_comment_id "0" = placeholder meaning "not yet synced to GitHub"
  # (set by cache-write-comment.sh when creating a new cache entry)
  if CACHED_ID=$(jq -r '.source_comment_id // "0"' "$CACHE_FILE" 2>/dev/null); then
    # Design Decision: Keep redundant -n check as zero-cost defensive guard
    # even though jq's // "0" fallback guarantees non-empty output,
    # edge cases with 2>/dev/null could theoretically yield empty string
    if [ "$CACHED_ID" != "0" ] && [ -n "$CACHED_ID" ]; then
      echo "Using cached comment ID: $CACHED_ID" >&2
      echo "$CACHED_ID"
      exit 0
    fi
  else
    echo "Warning: Cache file is corrupted, falling through to API: $CACHE_FILE" >&2
  fi
fi

# Fallback: find comment containing our metadata marker via API
if ! API_OUTPUT=$(gh api --paginate "/repos/{owner}/{repo}/issues/${PR_NUMBER}/comments" 2>&1); then
  echo "Error: Failed to fetch PR comments: $API_OUTPUT" >&2
  exit 1
fi

# Find all matching comment IDs
# --paginate concatenates multiple JSON arrays (one per page); .[] iterates across all of them
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
