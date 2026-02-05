#!/bin/bash
# Shared utility functions for pr-review-toolkit scripts
#
# Usage: source "$SCRIPT_DIR/lib/common.sh"

# Ensure .pr-review-cache/ is in .gitignore
# Call this when creating the cache directory
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

# Parse ISO 8601 timestamp to epoch seconds (cross-platform)
# Works on both macOS (BSD date) and Linux (GNU date)
#
# Usage: epoch=$(parse_iso_timestamp "2026-02-05T10:30:00Z")
# Returns: epoch seconds, or "0" on parse failure
parse_iso_timestamp() {
  local timestamp="$1"

  if [ -z "$timestamp" ] || [ "$timestamp" = "null" ]; then
    echo "0"
    return
  fi

  # Detect GNU vs BSD date
  if date --version >/dev/null 2>&1; then
    # GNU date (Linux)
    date -d "$timestamp" "+%s" 2>/dev/null || echo "0"
  else
    # BSD date (macOS)
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" "+%s" 2>/dev/null || echo "0"
  fi
}

# Get current epoch seconds
current_epoch() {
  date "+%s"
}
