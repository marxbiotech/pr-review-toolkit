#!/bin/bash
# Clean up cache files for merged or closed PRs
#
# Usage: ./cache-cleanup.sh [--dry-run] [--all]
# - --dry-run: Preview what would be deleted without actually deleting
# - --all: Remove ALL cache files including open PRs (use with caution)
#
# Exit codes: 0=success, 1=error

set -euo pipefail

CACHE_DIR=".pr-review-cache"

# Parse arguments
DRY_RUN=false
DELETE_ALL=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    --all)
      DELETE_ALL=true
      ;;
  esac
done

echo "=== PR Review Cache Cleanup ===" >&2
echo "" >&2

# Check if cache directory exists
if [ ! -d "$CACHE_DIR" ]; then
  echo "No cache directory found ($CACHE_DIR)" >&2
  exit 0
fi

# Find all cache files
CACHE_FILES=$(find "$CACHE_DIR" -name "pr-*.json" -type f 2>/dev/null || true)

if [ -z "$CACHE_FILES" ]; then
  echo "No cache files found" >&2
  exit 0
fi

DELETED_COUNT=0
KEPT_COUNT=0
ERROR_COUNT=0

if [ "$DRY_RUN" = true ]; then
  echo "DRY RUN - no files will be deleted" >&2
  echo "" >&2
fi

if [ "$DELETE_ALL" = true ]; then
  echo "WARNING: --all flag set, will delete ALL cache files" >&2
  echo "" >&2
fi

echo "Scanning cache files..." >&2
echo "" >&2

for CACHE_FILE in $CACHE_FILES; do
  # Extract PR number from filename
  PR_NUMBER=$(basename "$CACHE_FILE" | sed 's/pr-\([0-9]*\)\.json/\1/')
  CACHED_AT=$(jq -r '.cached_at // "unknown"' "$CACHE_FILE" 2>/dev/null || echo "unknown")

  if [ "$DELETE_ALL" = true ]; then
    # Delete all mode
    if [ "$DRY_RUN" = true ]; then
      echo "Would delete: $CACHE_FILE (PR #$PR_NUMBER, cached: $CACHED_AT)" >&2
    else
      rm -f "$CACHE_FILE"
      echo "Deleted: $CACHE_FILE (PR #$PR_NUMBER)" >&2
    fi
    DELETED_COUNT=$((DELETED_COUNT + 1))
    continue
  fi

  # Check PR state from GitHub
  PR_STATE=$(gh pr view "$PR_NUMBER" --json state -q '.state' 2>/dev/null || echo "NOT_FOUND")

  case "$PR_STATE" in
    MERGED|CLOSED|NOT_FOUND)
      # Delete cache for merged, closed, or deleted PRs
      if [ "$DRY_RUN" = true ]; then
        echo "Would delete: $CACHE_FILE (PR #$PR_NUMBER, state: $PR_STATE, cached: $CACHED_AT)" >&2
      else
        rm -f "$CACHE_FILE"
        echo "Deleted: $CACHE_FILE (PR #$PR_NUMBER, state: $PR_STATE)" >&2
      fi
      DELETED_COUNT=$((DELETED_COUNT + 1))
      ;;
    OPEN)
      echo "Keeping: $CACHE_FILE (PR #$PR_NUMBER is still open)" >&2
      KEPT_COUNT=$((KEPT_COUNT + 1))
      ;;
    *)
      echo "Error checking PR #$PR_NUMBER (state: $PR_STATE)" >&2
      ERROR_COUNT=$((ERROR_COUNT + 1))
      ;;
  esac
done

echo "" >&2
echo "=== Summary ===" >&2
if [ "$DRY_RUN" = true ]; then
  echo "Would delete: $DELETED_COUNT files" >&2
else
  echo "Deleted: $DELETED_COUNT files" >&2
fi
echo "Kept: $KEPT_COUNT files" >&2
if [ "$ERROR_COUNT" -gt 0 ]; then
  echo "Errors: $ERROR_COUNT files" >&2
fi

# Remove cache directory if empty
if [ "$DRY_RUN" = false ] && [ -d "$CACHE_DIR" ]; then
  if [ -z "$(ls -A "$CACHE_DIR" 2>/dev/null)" ]; then
    rmdir "$CACHE_DIR"
    echo "" >&2
    echo "Removed empty cache directory" >&2
  fi
fi
