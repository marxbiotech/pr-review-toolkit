#!/bin/bash
# Create or update PR review comment
#
# Usage: ./upsert-review-comment.sh <CONTENT_FILE> [PR_NUMBER]
# - CONTENT_FILE: Path to file containing the review content (markdown)
# - PR_NUMBER: Optional, defaults to current branch's PR

set -euo pipefail

CONTENT_FILE="${1:-}"
PR_NUMBER="${2:-}"

if [ -z "$CONTENT_FILE" ]; then
  echo "Error: Content file path required" >&2
  echo "Usage: $0 <CONTENT_FILE> [PR_NUMBER]" >&2
  exit 1
fi

if [ ! -f "$CONTENT_FILE" ]; then
  echo "Error: Content file not found: $CONTENT_FILE" >&2
  exit 1
fi

# Security: Only allow files from /tmp/ or /var/folders/ (macOS temp) to prevent data exfiltration
# This mitigates indirect prompt injection attacks that could trick LLM into posting sensitive files
REAL_PATH=$(realpath "$CONTENT_FILE")
if [[ "$REAL_PATH" != /tmp/* ]] && [[ "$REAL_PATH" != /private/tmp/* ]] && [[ "$REAL_PATH" != /var/folders/* ]]; then
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

# If no PR number provided, try to get from current branch
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(gh pr view --json number -q '.number' || echo "")
fi

if [ -z "$PR_NUMBER" ]; then
  echo "Error: No PR number found. Ensure you're on a branch with an open PR or provide PR number." >&2
  exit 1
fi

# Find existing review comment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMENT_ID=$("$SCRIPT_DIR/find-review-comment.sh" "$PR_NUMBER")

if [ -n "$COMMENT_ID" ]; then
  # Update existing comment
  if ! COMMENT_URL=$(gh api --method PATCH "/repos/{owner}/{repo}/issues/comments/${COMMENT_ID}" \
    -F body="@${CONTENT_FILE}" \
    --jq '.html_url'); then
    echo "Error: Failed to update comment $COMMENT_ID" >&2
    exit 1
  fi
  echo "$COMMENT_URL"
  echo "Updated existing comment: $COMMENT_ID"
else
  # Create new comment
  if ! COMMENT_URL=$(gh api --method POST "/repos/{owner}/{repo}/issues/${PR_NUMBER}/comments" \
    -F body="@${CONTENT_FILE}" \
    --jq '.html_url'); then
    echo "Error: Failed to create comment on PR #$PR_NUMBER" >&2
    exit 1
  fi
  echo "$COMMENT_URL"
  echo "Created new comment on PR #$PR_NUMBER"
fi
