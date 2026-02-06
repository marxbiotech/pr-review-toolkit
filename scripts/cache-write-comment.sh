#!/bin/bash
# Write PR review comment with local cache support
# Updates local cache and optionally syncs to GitHub
#
# Usage: ./cache-write-comment.sh <CONTENT_FILE> [PR_NUMBER] [--local-only]
#        ./cache-write-comment.sh --stdin [PR_NUMBER] [--local-only]
#        ./cache-write-comment.sh --sync-from-cache [PR_NUMBER] [--force]
# - CONTENT_FILE: Path to file containing the review content (markdown)
# - --stdin: Read content from stdin instead of a file
# - PR_NUMBER: Optional, defaults to current branch's PR
# - --local-only: Only update local cache, don't sync to GitHub
# - --sync-from-cache: Re-sync existing local cache to GitHub (recovery mode)
# - --force: Skip freshness check (use with --sync-from-cache)
#
# Exit codes: 0=success, 1=github sync failed (local cache is up-to-date),
#             2=local error, 3=remote is newer (use --force to override)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CACHE_DIR=".pr-review-cache"
MAX_RETRIES=3
RETRY_INTERVAL=3

# Parse arguments
CONTENT_FILE=""
PR_NUMBER=""
LOCAL_ONLY=false
SYNC_FROM_CACHE=false
READ_STDIN=false
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --local-only)
      LOCAL_ONLY=true
      ;;
    --sync-from-cache)
      SYNC_FROM_CACHE=true
      ;;
    --stdin)
      READ_STDIN=true
      ;;
    --force)
      FORCE=true
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

# --stdin mode: read content from stdin into a variable
if [ "$READ_STDIN" = true ]; then
  # With --stdin, the first positional arg is PR_NUMBER, not CONTENT_FILE
  if [ -n "$CONTENT_FILE" ] && [ -z "$PR_NUMBER" ]; then
    PR_NUMBER="$CONTENT_FILE"
    CONTENT_FILE=""
  fi

  CONTENT=$(cat)

  if [ -z "$CONTENT" ]; then
    echo "Error: stdin content is empty" >&2
    exit 2
  fi
fi

# --sync-from-cache mode: read content from local cache and sync to GitHub
if [ "$SYNC_FROM_CACHE" = true ]; then
  # PR number can be the first positional arg when using --sync-from-cache
  if [ -n "$CONTENT_FILE" ] && [ -z "$PR_NUMBER" ]; then
    PR_NUMBER="$CONTENT_FILE"
    CONTENT_FILE=""
  fi

  if [ -z "$PR_NUMBER" ]; then
    PR_NUMBER=$("$SCRIPT_DIR/get-pr-number.sh" || echo "")
  fi

  if [ -z "$PR_NUMBER" ]; then
    echo "Error: No PR number found." >&2
    exit 2
  fi

  CACHE_FILE="${CACHE_DIR}/pr-${PR_NUMBER}.json"
  if [ ! -f "$CACHE_FILE" ]; then
    echo "Error: No local cache found for PR #$PR_NUMBER ($CACHE_FILE)" >&2
    exit 2
  fi

  # Read content from cache
  CONTENT=$(jq -r '.content' "$CACHE_FILE")

  if [ -z "$CONTENT" ]; then
    echo "Error: Cache content is empty for PR #$PR_NUMBER" >&2
    exit 2
  fi

  # Freshness check: ensure local cache is newer than remote
  if [ "$FORCE" = false ]; then
    LOCAL_CACHED_AT=$(jq -r '.cached_at // ""' "$CACHE_FILE")
    COMMENT_ID=$(jq -r '.source_comment_id // "0"' "$CACHE_FILE")

    if [ -n "$COMMENT_ID" ] && [ "$COMMENT_ID" != "0" ]; then
      REMOTE_UPDATED_AT=$(gh api "/repos/{owner}/{repo}/issues/comments/${COMMENT_ID}" --jq '.updated_at' 2>/dev/null || echo "")

      if [ -n "$REMOTE_UPDATED_AT" ] && [ -n "$LOCAL_CACHED_AT" ]; then
        LOCAL_EPOCH=$(parse_iso_timestamp "$LOCAL_CACHED_AT")
        REMOTE_EPOCH=$(parse_iso_timestamp "$REMOTE_UPDATED_AT")

        if [ "$REMOTE_EPOCH" -gt "$LOCAL_EPOCH" ]; then
          echo "========================================" >&2
          echo "Aborted: remote comment is NEWER than local cache." >&2
          echo "" >&2
          echo "  Local cached_at:  $LOCAL_CACHED_AT" >&2
          echo "  Remote updated_at: $REMOTE_UPDATED_AT" >&2
          echo "" >&2
          echo "Pushing would overwrite newer remote changes." >&2
          echo "To force push anyway, add --force:" >&2
          echo "  $0 --sync-from-cache $PR_NUMBER --force" >&2
          echo "========================================" >&2
          exit 3
        fi
      fi
    fi
    echo "Freshness check passed: local cache is up-to-date" >&2
  else
    echo "Freshness check skipped (--force)" >&2
  fi

  echo "Re-syncing local cache to GitHub for PR #$PR_NUMBER..." >&2
  # Fall through to the GitHub sync section below (skip local cache write)

elif [ "$READ_STDIN" = false ]; then
  # File mode — need a CONTENT_FILE
  if [ -z "$CONTENT_FILE" ]; then
    echo "Error: Content file path required" >&2
    echo "Usage: $0 <CONTENT_FILE> [PR_NUMBER] [--local-only]" >&2
    echo "       $0 --stdin [PR_NUMBER] [--local-only]" >&2
    echo "       $0 --sync-from-cache [PR_NUMBER]" >&2
    exit 2
  fi

  if [ ! -f "$CONTENT_FILE" ]; then
    echo "Error: Content file not found: $CONTENT_FILE" >&2
    exit 2
  fi

  CONTENT=$(cat "$CONTENT_FILE")
fi

# If no PR number provided, try to get from current branch
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$("$SCRIPT_DIR/get-pr-number.sh" || echo "")
fi

if [ -z "$PR_NUMBER" ]; then
  echo "Error: No PR number found. Ensure you're on a branch with an open PR or provide PR number." >&2
  exit 2
fi

CACHE_FILE="${CACHE_DIR}/pr-${PR_NUMBER}.json"

# Write local cache (skip in --sync-from-cache mode, cache is already up-to-date)
if [ "$SYNC_FROM_CACHE" = false ]; then
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
fi

# Sync to GitHub with retry — pipes content via stdin, no temp files
sync_to_github() {
  local attempt=1
  local output

  while [ $attempt -le $MAX_RETRIES ]; do
    echo "Syncing to GitHub (attempt $attempt/$MAX_RETRIES)..." >&2

    if output=$(echo "$CONTENT" | "$SCRIPT_DIR/upsert-review-comment.sh" --stdin "$PR_NUMBER" 2>&1); then
      # Success — extract comment URL (first line of output)
      local comment_url
      comment_url=$(echo "$output" | head -1)
      echo "$comment_url"

      # Update comment ID in cache
      local new_comment_id
      if ! new_comment_id=$("$SCRIPT_DIR/find-review-comment.sh" "$PR_NUMBER" 2>&1); then
        echo "Warning: Could not retrieve comment ID for cache update: $new_comment_id" >&2
        new_comment_id=""
      fi
      if [ -n "$new_comment_id" ] && [ "$new_comment_id" != "0" ]; then
        jq --argjson comment_id "$new_comment_id" '.source_comment_id = $comment_id' "$CACHE_FILE" > "${CACHE_FILE}.tmp"
        mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
      fi

      echo "Successfully synced to GitHub" >&2
      return 0
    fi

    echo "Attempt $attempt failed: $output" >&2

    if [ $attempt -lt $MAX_RETRIES ]; then
      echo "Retrying in ${RETRY_INTERVAL}s..." >&2
      sleep "$RETRY_INTERVAL"
    fi

    attempt=$((attempt + 1))
  done

  # All retries exhausted
  echo "" >&2
  echo "========================================" >&2
  echo "GitHub sync failed after $MAX_RETRIES attempts." >&2
  echo "Local cache is UP-TO-DATE: $CACHE_FILE" >&2
  echo "" >&2
  echo "To retry later, run:" >&2
  echo "  $0 --sync-from-cache $PR_NUMBER" >&2
  echo "========================================" >&2
  return 1
}

if ! sync_to_github; then
  exit 1
fi
