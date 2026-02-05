#!/bin/bash
# Write PR review comment with local cache support
# Updates local cache and optionally syncs to GitHub
#
# Usage: ./cache-write-comment.sh <CONTENT_FILE> [PR_NUMBER] [--local-only]
# - CONTENT_FILE: Path to file containing the review content (markdown)
# - PR_NUMBER: Optional, defaults to current branch's PR
# - --local-only: Only update local cache, don't sync to GitHub
#
# Exit codes: 0=success, 1=error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR=".pr-review-cache"

# Ensure .pr-review-cache/ is in .gitignore
ensure_gitignore() {
  local GITIGNORE=".gitignore"
  local ENTRY=".pr-review-cache/"

  # Only run in git repo
  if [ ! -d ".git" ]; then
    return
  fi

  # Check if entry already exists (avoid duplicates)
  if [ -f "$GITIGNORE" ] && grep -qxF "$ENTRY" "$GITIGNORE"; then
    return
  fi

  # Add entry and notify user
  echo "$ENTRY" >> "$GITIGNORE"
  echo "Added '$ENTRY' to .gitignore" >&2
}

# Parse arguments
CONTENT_FILE=""
PR_NUMBER=""
LOCAL_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --local-only)
      LOCAL_ONLY=true
      ;;
    *)
      if [ -z "$CONTENT_FILE" ]; then
        CONTENT_FILE="$arg"
      elif [ -z "$PR_NUMBER" ]; then
        PR_NUMBER="$arg"
      fi
      ;;
  esac
done

if [ -z "$CONTENT_FILE" ]; then
  echo "Error: Content file path required" >&2
  echo "Usage: $0 <CONTENT_FILE> [PR_NUMBER] [--local-only]" >&2
  exit 1
fi

if [ ! -f "$CONTENT_FILE" ]; then
  echo "Error: Content file not found: $CONTENT_FILE" >&2
  exit 1
fi

# If no PR number provided, try to get from current branch
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(gh pr view --json number -q '.number' 2>/dev/null || echo "")
fi

if [ -z "$PR_NUMBER" ]; then
  echo "Error: No PR number found. Ensure you're on a branch with an open PR or provide PR number." >&2
  exit 1
fi

CACHE_FILE="${CACHE_DIR}/pr-${PR_NUMBER}.json"

# Read content from file
CONTENT=$(cat "$CONTENT_FILE")

# Get existing cache metadata or fetch fresh
COMMENT_ID=""
if [ -f "$CACHE_FILE" ]; then
  COMMENT_ID=$(jq -r '.source_comment_id // ""' "$CACHE_FILE")
fi

# Get PR metadata
PR_INFO=$(gh pr view "$PR_NUMBER" --json state,headRefName,baseRefName 2>/dev/null || echo '{}')
PR_STATE=$(echo "$PR_INFO" | jq -r '.state // "UNKNOWN"')
BRANCH=$(echo "$PR_INFO" | jq -r '.headRefName // "unknown"')
BASE=$(echo "$PR_INFO" | jq -r '.baseRefName // "main"')

# Calculate content hash
CONTENT_HASH="sha256:$(echo -n "$CONTENT" | shasum -a 256 | cut -d' ' -f1)"

# Create cache directory if needed
if [ ! -d "$CACHE_DIR" ]; then
  mkdir -p "$CACHE_DIR"
  ensure_gitignore
fi

# Update local cache
CACHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# If we don't have a comment ID yet, use 0 as placeholder (will be updated after GitHub sync)
if [ -z "$COMMENT_ID" ]; then
  COMMENT_ID=0
fi

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

echo "Local cache updated: $CACHE_FILE" >&2

if [ "$LOCAL_ONLY" = true ]; then
  echo "Local-only mode: skipping GitHub sync" >&2
  exit 0
fi

# Sync to GitHub using upsert script
echo "Syncing to GitHub..." >&2
if ! OUTPUT=$("$SCRIPT_DIR/upsert-review-comment.sh" "$CONTENT_FILE" "$PR_NUMBER" 2>&1); then
  echo "Error: Failed to sync to GitHub: $OUTPUT" >&2
  exit 1
fi

# Extract comment URL (first line of output)
COMMENT_URL=$(echo "$OUTPUT" | head -1)
echo "$COMMENT_URL"

# Try to extract and update comment ID in cache
# The upsert script outputs the comment ID in the second line message
NEW_COMMENT_ID=$("$SCRIPT_DIR/find-review-comment.sh" "$PR_NUMBER" 2>/dev/null || echo "")
if [ -n "$NEW_COMMENT_ID" ] && [ "$NEW_COMMENT_ID" != "0" ]; then
  # Update cache with actual comment ID
  jq --argjson comment_id "$NEW_COMMENT_ID" '.source_comment_id = $comment_id' "$CACHE_FILE" > "${CACHE_FILE}.tmp"
  mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
fi

echo "Successfully synced to GitHub" >&2
