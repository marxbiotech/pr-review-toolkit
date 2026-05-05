#!/bin/bash
# Write PR review comment with local cache support
# Updates local cache and optionally syncs to GitHub
#
# Usage: ./cache-write-comment.sh <CONTENT_FILE> [PR_NUMBER] [--local-only] [--expected-content-hash HASH]
#        ./cache-write-comment.sh --stdin [PR_NUMBER] [--local-only] [--expected-content-hash HASH]
#        ./cache-write-comment.sh --sync-from-cache [PR_NUMBER] [--force]
# - CONTENT_FILE: Path to file containing the review content (markdown)
# - --stdin: Read content from stdin instead of a file
# - PR_NUMBER: Optional, defaults to current branch's PR
# - --local-only: Only update local cache, don't sync to GitHub
# - --sync-from-cache: Re-sync existing local cache to GitHub (recovery mode)
# - --force: Skip freshness check (use with --sync-from-cache)
# - --expected-content-hash: Abort if the local cache hash changed before writing
#
# Exit codes: 0=success, 1=github sync failed (local cache is up-to-date)
#                            OR post-sync cache repair failed (stale_source_id flag set),
#             2=local error, 3=remote is newer (use --force to override),
#             4=content hash mismatch (stale read-modify-write)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CACHE_DIR=".pr-review-cache"
MAX_RETRIES=3
RETRY_INTERVAL=3

# Validate --expected-content-hash value: must be non-empty and sha256:64-hex format
validate_expected_content_hash() {
  local val="$1"
  if [ -z "$val" ]; then
    echo "Error: --expected-content-hash requires a non-empty value" >&2
    exit 2
  fi
  if ! [[ "$val" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Error: --expected-content-hash must be 'sha256:' followed by 64 hex chars, got: $val" >&2
    exit 2
  fi
}

# Parse arguments
CONTENT_FILE=""
PR_NUMBER=""
LOCAL_ONLY=false
SYNC_FROM_CACHE=false
READ_STDIN=false
FORCE=false
EXPECTED_CONTENT_HASH=""

while [ $# -gt 0 ]; do
  arg="$1"
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
    --expected-content-hash)
      shift
      if [ $# -eq 0 ]; then
        echo "Error: --expected-content-hash requires a value" >&2
        exit 2
      fi
      EXPECTED_CONTENT_HASH="$1"
      validate_expected_content_hash "$EXPECTED_CONTENT_HASH"
      ;;
    --expected-content-hash=*)
      EXPECTED_CONTENT_HASH="${arg#*=}"
      validate_expected_content_hash "$EXPECTED_CONTENT_HASH"
      ;;
    *)
      if [ -z "$CONTENT_FILE" ]; then
        CONTENT_FILE="$arg"
      elif [ -z "$PR_NUMBER" ]; then
        PR_NUMBER="$arg"
      fi
      ;;
  esac
  shift
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

        # Validate both epochs are non-empty integers; an empty/non-numeric value
        # from parse_iso_timestamp would silently make the -gt comparison false,
        # bypassing the freshness check.
        if ! [[ "$LOCAL_EPOCH" =~ ^[0-9]+$ ]] || ! [[ "$REMOTE_EPOCH" =~ ^[0-9]+$ ]]; then
          echo "========================================" >&2
          echo "Aborted: could not parse one or both timestamps for freshness check." >&2
          echo "" >&2
          echo "  Local cached_at:   $LOCAL_CACHED_AT (parsed: ${LOCAL_EPOCH:-<empty>})" >&2
          echo "  Remote updated_at: $REMOTE_UPDATED_AT (parsed: ${REMOTE_EPOCH:-<empty>})" >&2
          echo "" >&2
          echo "Refusing to push without a verifiable freshness check." >&2
          echo "If you have manually verified local is newer, retry with --force:" >&2
          echo "  $0 --sync-from-cache $PR_NUMBER --force" >&2
          echo "========================================" >&2
          exit 3
        fi

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
    echo "Usage: $0 <CONTENT_FILE> [PR_NUMBER] [--local-only] [--expected-content-hash HASH]" >&2
    echo "       $0 --stdin [PR_NUMBER] [--local-only] [--expected-content-hash HASH]" >&2
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

# Producer-side sanity: content must contain exactly one '<!-- pr-review-metadata' marker.
# 0 markers -> not a review comment (refuse to poison the cache).
# >1 markers -> downstream replace/upgrade scripts will refuse to handle a multi-block payload,
#   so refuse here at the producer instead of writing a poison pill.
# Note: `|| true` because `grep -c` returns 1 on zero matches under `set -euo pipefail`.
META_COUNT=$(printf '%s\n' "$CONTENT" | grep -c '^<!-- pr-review-metadata' || true)
if [ "$META_COUNT" -eq 0 ]; then
  echo "Error: content does not contain '<!-- pr-review-metadata' marker; refusing to write" >&2
  exit 2
fi
if [ "$META_COUNT" -gt 1 ]; then
  echo "Error: content contains $META_COUNT '<!-- pr-review-metadata' markers; expected exactly one. Refusing to write." >&2
  exit 2
fi

CACHE_FILE="${CACHE_DIR}/pr-${PR_NUMBER}.json"

# Write local cache (skip in --sync-from-cache mode, cache is already up-to-date)
if [ "$SYNC_FROM_CACHE" = false ]; then
  if [ -n "$EXPECTED_CONTENT_HASH" ]; then
    CURRENT_CONTENT_HASH=""
    if [ -f "$CACHE_FILE" ]; then
      CURRENT_CONTENT_HASH=$(jq -r '.content_hash // ""' "$CACHE_FILE")
    fi

    if [ "$CURRENT_CONTENT_HASH" != "$EXPECTED_CONTENT_HASH" ]; then
      echo "========================================" >&2
      echo "Aborted: local cache content hash changed before write." >&2
      echo "" >&2
      echo "  Expected: $EXPECTED_CONTENT_HASH" >&2
      echo "  Current:  ${CURRENT_CONTENT_HASH:-<no cache>}" >&2
      echo "" >&2
      echo "Re-read the PR review comment, merge your update, and retry." >&2
      echo "========================================" >&2
      exit 4
    fi

    echo "Content hash check passed: $EXPECTED_CONTENT_HASH" >&2
  fi

  # Get existing cache metadata or fetch fresh
  COMMENT_ID=""
  if [ -f "$CACHE_FILE" ]; then
    COMMENT_ID=$(jq -r '.source_comment_id // "0"' "$CACHE_FILE")
  fi

  # Get PR metadata
  set +e
  PR_INFO=$(gh pr view "$PR_NUMBER" --json state,headRefName,baseRefName 2>/tmp/gh-pr-view-err.$$)
  gh_exit=$?
  set -e

  if [ "$gh_exit" -ne 0 ]; then
    echo "Warning: gh pr view failed (exit $gh_exit); cache envelope metadata degraded to UNKNOWN/unknown/main." >&2
    if [ -s /tmp/gh-pr-view-err.$$ ]; then
      echo "  gh stderr:" >&2
      sed 's/^/    /' /tmp/gh-pr-view-err.$$ >&2
    fi
    PR_INFO='{}'
  fi
  rm -f /tmp/gh-pr-view-err.$$

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
    }' > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"

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

      # Retry the post-sync comment-ID lookup. Without a real ID the cache
      # keeps the bootstrap placeholder (0), and freshness checks in
      # --sync-from-cache mode short-circuit on it — opening a silent
      # overwrite window. Use the same retry budget as the upsert above.
      local new_comment_id=""
      local find_output
      local lookup_attempt=1
      while [ $lookup_attempt -le $MAX_RETRIES ]; do
        # NOTE: do NOT redirect stderr to stdout here. find-review-comment.sh
        # writes the comment ID to stdout and info messages (e.g.
        # "Using cached comment ID: ...") to stderr; mixing them produces
        # multi-line non-numeric input that downstream jq --argjson then
        # rejects, which previously truncated the cache to 0 bytes.
        if find_output=$("$SCRIPT_DIR/find-review-comment.sh" "$PR_NUMBER"); then
          # Strict numeric validation: rejects empty, multi-line,
          # non-numeric, and the bootstrap "0" placeholder in one check.
          if [[ "$find_output" =~ ^[0-9]+$ ]] && [ "$find_output" != "0" ]; then
            new_comment_id="$find_output"
            break
          fi
        fi
        if [ $lookup_attempt -lt $MAX_RETRIES ]; then
          echo "Post-sync comment-ID lookup attempt $lookup_attempt/$MAX_RETRIES failed; retrying in ${RETRY_INTERVAL}s..." >&2
          sleep "$RETRY_INTERVAL"
        fi
        lookup_attempt=$((lookup_attempt + 1))
      done

      if [ -n "$new_comment_id" ] && [[ "$new_comment_id" =~ ^[0-9]+$ ]]; then
        # Atomic repair: write to a unique mktemp path and only mv on jq
        # success. A separate mktemp filename avoids collisions with
        # ${CACHE_FILE}.tmp used elsewhere; chaining with && ensures mv
        # never runs on a 0-byte tmp file when jq fails.
        local repair_tmp
        repair_tmp=$(mktemp "${CACHE_FILE}.repair.XXXXXX")
        if jq --argjson comment_id "$new_comment_id" '.source_comment_id = $comment_id' "$CACHE_FILE" > "$repair_tmp" \
           && mv "$repair_tmp" "$CACHE_FILE"; then
          echo "Successfully synced to GitHub" >&2
          return 0
        else
          rm -f "$repair_tmp"
          echo "Warning: post-sync source_comment_id repair failed; cache not updated." >&2
          # fall through to the stale-flag path below
        fi
      fi

      # Retries exhausted (or the repair write failed) — GitHub upsert
      # succeeded, but we couldn't repair the cache's source_comment_id.
      # Mark the envelope stale so future freshness checks can refuse to
      # silently overwrite remote changes. Use a unique mktemp path and
      # chain with && so a failed jq here also cannot poison the cache.
      local stale_tmp
      stale_tmp=$(mktemp "${CACHE_FILE}.stale.XXXXXX")
      if jq --argjson stale true '.stale_source_id = $stale' "$CACHE_FILE" > "$stale_tmp" \
         && mv "$stale_tmp" "$CACHE_FILE"; then
        :
      else
        rm -f "$stale_tmp"
        echo "Warning: failed to set stale_source_id flag on cache." >&2
      fi

      echo "" >&2
      echo "========================================" >&2
      echo "GitHub sync succeeded, but post-sync cache repair failed." >&2
      echo "" >&2
      echo "  Failed step: find-review-comment.sh after $MAX_RETRIES attempts" >&2
      echo "  Stale state: source_comment_id remains the bootstrap placeholder;" >&2
      echo "               freshness checks will be skipped on this cache." >&2
      echo "  Envelope flag set: stale_source_id=true" >&2
      echo "" >&2
      echo "To recover, run:" >&2
      echo "  scripts/cache-sync.sh \"$PR_NUMBER\" --force-refresh" >&2
      echo "  (repopulates the cache from GitHub)" >&2
      echo "========================================" >&2
      return 1
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
