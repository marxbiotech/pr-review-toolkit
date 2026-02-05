#!/bin/bash
# Read PR review comment with local cache support
# Checks local cache first, falls back to GitHub API if cache miss
#
# Usage: ./cache-read-comment.sh [PR_NUMBER] [--force-refresh]
# Output: Comment content to stdout
# Exit codes: 0=success, 1=error, 2=no comment found
#
# Cache files are stored in the target repo at .pr-review-cache/pr-{N}.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR=".pr-review-cache"

# Parse arguments
PR_NUMBER=""
FORCE_REFRESH=false

for arg in "$@"; do
  case "$arg" in
    --force-refresh)
      FORCE_REFRESH=true
      ;;
    *)
      if [ -z "$PR_NUMBER" ]; then
        PR_NUMBER="$arg"
      fi
      ;;
  esac
done

# If no PR number provided, try to get from current branch
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(gh pr view --json number -q '.number' 2>/dev/null || echo "")
fi

if [ -z "$PR_NUMBER" ]; then
  echo "Error: No PR number found. Ensure you're on a branch with an open PR or provide PR number." >&2
  exit 1
fi

CACHE_FILE="${CACHE_DIR}/pr-${PR_NUMBER}.json"

# Function to read from cache
read_from_cache() {
  if [ -f "$CACHE_FILE" ]; then
    local cached_at
    cached_at=$(jq -r '.cached_at // "unknown"' "$CACHE_FILE")
    echo "Using cached comment (cached at: $cached_at)" >&2
    jq -r '.content' "$CACHE_FILE"
    return 0
  fi
  return 1
}

# Function to fetch from GitHub and update cache
fetch_and_cache() {
  # Find the review comment
  COMMENT_ID=$("$SCRIPT_DIR/find-review-comment.sh" "$PR_NUMBER")

  if [ -z "$COMMENT_ID" ]; then
    echo "No review comment found for PR #$PR_NUMBER" >&2
    exit 2
  fi

  echo "Fetching comment $COMMENT_ID from GitHub..." >&2

  # Fetch comment body
  if ! CONTENT=$(gh api "/repos/{owner}/{repo}/issues/comments/${COMMENT_ID}" --jq '.body' 2>&1); then
    echo "Error: Failed to fetch comment: $CONTENT" >&2
    exit 1
  fi

  # Get PR metadata
  PR_INFO=$(gh pr view "$PR_NUMBER" --json state,headRefName,baseRefName 2>/dev/null || echo '{}')
  PR_STATE=$(echo "$PR_INFO" | jq -r '.state // "UNKNOWN"')
  BRANCH=$(echo "$PR_INFO" | jq -r '.headRefName // "unknown"')
  BASE=$(echo "$PR_INFO" | jq -r '.baseRefName // "main"')

  # Calculate content hash
  CONTENT_HASH="sha256:$(echo -n "$CONTENT" | shasum -a 256 | cut -d' ' -f1)"

  # Create cache directory if needed
  mkdir -p "$CACHE_DIR"

  # Write cache file
  CACHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -n \
    --arg schema_version "1.0" \
    --argjson pr_number "$PR_NUMBER" \
    --argjson comment_id "$COMMENT_ID" \
    --arg cached_at "$CACHED_AT" \
    --arg pr_state "$PR_STATE" \
    --arg branch "$BRANCH" \
    --arg base "$BASE" \
    --arg content "$CONTENT" \
    --arg content_hash "$CONTENT_HASH" \
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

  echo "Cache updated: $CACHE_FILE" >&2
  echo "$CONTENT"
}

# Main logic
if [ "$FORCE_REFRESH" = true ]; then
  echo "Force refresh requested" >&2
  fetch_and_cache
elif ! read_from_cache; then
  echo "Cache miss, fetching from GitHub..." >&2
  fetch_and_cache
fi
