#!/bin/bash
# Create or update PR review comment
#
# Usage: ./upsert-review-comment.sh <CONTENT_FILE> [PR_NUMBER]
#        ./upsert-review-comment.sh --stdin [PR_NUMBER]
# - CONTENT_FILE: Path to file containing the review content (markdown)
# - --stdin: Read content from stdin instead of a file
# - PR_NUMBER: Optional, defaults to current branch's PR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
CONTENT_FILE=""
PR_NUMBER=""
READ_STDIN=false

for arg in "$@"; do
  case "$arg" in
    --stdin)
      READ_STDIN=true
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

# Determine content source
if [ "$READ_STDIN" = true ]; then
  # --stdin mode: first positional arg is PR_NUMBER
  if [ -n "$CONTENT_FILE" ] && [ -z "$PR_NUMBER" ]; then
    PR_NUMBER="$CONTENT_FILE"
    CONTENT_FILE=""
  fi

  # Read content from stdin
  CONTENT=$(cat)

  if [ -z "$CONTENT" ]; then
    echo "Error: stdin content is empty" >&2
    exit 1
  fi

  # Security: Verify content contains pr-review-metadata marker
  if ! echo "$CONTENT" | grep -q "<!-- pr-review-metadata"; then
    echo "Error: Security restriction - content must contain '<!-- pr-review-metadata' marker" >&2
    echo "This ensures only valid PR review content can be posted" >&2
    exit 1
  fi
else
  # File mode
  if [ -z "$CONTENT_FILE" ]; then
    echo "Error: Content file path required" >&2
    echo "Usage: $0 <CONTENT_FILE> [PR_NUMBER]" >&2
    echo "       $0 --stdin [PR_NUMBER]" >&2
    exit 1
  fi

  if [ ! -f "$CONTENT_FILE" ]; then
    echo "Error: Content file not found: $CONTENT_FILE" >&2
    exit 1
  fi

  # Security: Only allow files from /tmp/ or /var/folders/ (macOS temp) to prevent data exfiltration
  # This mitigates indirect prompt injection attacks that could trick LLM into posting sensitive files
  REAL_PATH=$(realpath "$CONTENT_FILE")
  if [[ "$REAL_PATH" != /tmp/* ]] && [[ "$REAL_PATH" != /private/tmp/* ]] && [[ "$REAL_PATH" != /var/folders/* ]] && [[ "$REAL_PATH" != /private/var/folders/* ]]; then
    echo "Error: Security restriction - only files in /tmp/ or system temp directories are allowed" >&2
    echo "Received path: $CONTENT_FILE (resolved to: $REAL_PATH)" >&2
    exit 1
  fi

  # Security: Verify file contains pr-review-metadata marker to ensure it's a valid review file
  if ! grep -q "<!-- pr-review-metadata" "$CONTENT_FILE"; then
    echo "Error: Security restriction - file must contain '<!-- pr-review-metadata' marker" >&2
    echo "This ensures only valid PR review content can be posted" >&2
    exit 1
  fi

  CONTENT=$(cat "$CONTENT_FILE")
fi

# If no PR number provided, try to get from current branch
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$("$SCRIPT_DIR/get-pr-number.sh" || echo "")
fi

if [ -z "$PR_NUMBER" ]; then
  echo "Error: No PR number found. Ensure you're on a branch with an open PR or provide PR number." >&2
  exit 1
fi

# Find existing review comment
if ! COMMENT_ID=$("$SCRIPT_DIR/find-review-comment.sh" "$PR_NUMBER"); then
  echo "Warning: Could not find existing review comment, will create new" >&2
  COMMENT_ID=""
fi

# Try PATCH if we have an existing comment ID
if [ -n "$COMMENT_ID" ]; then
  PATCH_OUTPUT=""
  if PATCH_OUTPUT=$(echo "$CONTENT" | gh api --method PATCH "/repos/{owner}/{repo}/issues/comments/${COMMENT_ID}" \
    -F body=@- \
    --jq '.html_url' 2>&1); then
    echo "$PATCH_OUTPUT"
    echo "Updated existing comment: $COMMENT_ID"
    exit 0
  fi

  # PATCH failed — only fall through to POST on 404 (comment deleted)
  if echo "$PATCH_OUTPUT" | grep -q '"Not Found"'; then
    echo "Warning: Comment $COMMENT_ID no longer exists, will create new comment" >&2
    # Invalidate stale cache entry to prevent repeated 404 cycles
    # Design Decision: Not guarding jq/mv with if-block despite set -e — jq and mv operate on a
    # file we just confirmed exists, on content we control; failure here (disk full, permissions)
    # indicates a systemic issue where proceeding to POST would also likely fail.
    CACHE_FILE=".pr-review-cache/pr-${PR_NUMBER}.json"
    if [ -f "$CACHE_FILE" ]; then
      jq '.source_comment_id = 0' "$CACHE_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
      echo "Invalidated stale comment ID in cache: $CACHE_FILE" >&2
    fi
  else
    echo "Error: Failed to update comment $COMMENT_ID" >&2
    echo "  Error: $PATCH_OUTPUT" >&2
    exit 1
  fi
fi

# Create new comment (no existing comment, or existing was deleted)
if ! COMMENT_URL=$(echo "$CONTENT" | gh api --method POST "/repos/{owner}/{repo}/issues/${PR_NUMBER}/comments" \
  -F body=@- \
  --jq '.html_url'); then
  echo "Error: Failed to create comment on PR #$PR_NUMBER" >&2
  exit 1
fi
echo "$COMMENT_URL"
echo "Created new comment on PR #$PR_NUMBER"
