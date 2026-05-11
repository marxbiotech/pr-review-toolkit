#!/bin/bash
# Get PR number for current branch with local caching
# Caches branch → PR number mapping to reduce GitHub API calls
#
# Usage: ./get-pr-number.sh [--no-cache] [--refresh]
# Output: PR number to stdout
# Exit codes: 0=success, 1=no PR found or error
#
# Cache file: .pr-review-cache/branch-map.json
# TTL: 1 hour

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CACHE_DIR=".pr-review-cache"
CACHE_FILE="${CACHE_DIR}/branch-map.json"
TTL_SECONDS=3600  # 1 hour

# Parse arguments
USE_CACHE=true
FORCE_REFRESH=false

for arg in "$@"; do
  case "$arg" in
    --no-cache)
      USE_CACHE=false
      ;;
    --refresh)
      FORCE_REFRESH=true
      ;;
  esac
done

# Get current branch name
get_branch_name() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

# Initialize cache file if needed
init_cache() {
  if [ ! -d "$CACHE_DIR" ]; then
    mkdir -p "$CACHE_DIR"
    ensure_gitignore
  fi

  if [ ! -f "$CACHE_FILE" ]; then
    echo '{"schema_version":"1.0","updated_at":"","mappings":{}}' > "$CACHE_FILE"
  fi
}

# Check if cached entry is still valid (not expired)
is_cache_valid() {
  local cached_at="$1"
  local cached_epoch
  local now

  cached_epoch=$(parse_iso_timestamp "$cached_at")
  now=$(current_epoch)

  local age=$((now - cached_epoch))

  if [ "$age" -lt "$TTL_SECONDS" ]; then
    return 0
  else
    return 1
  fi
}

# Read PR number from cache
read_from_cache() {
  local branch="$1"

  if [ ! -f "$CACHE_FILE" ]; then
    return 1
  fi

  local entry
  entry=$(jq -r --arg branch "$branch" '.mappings[$branch] // empty' "$CACHE_FILE")

  if [ -z "$entry" ]; then
    return 1
  fi

  local pr_number cached_at pr_state
  pr_number=$(echo "$entry" | jq -r '.pr_number // empty')
  cached_at=$(echo "$entry" | jq -r '.cached_at // empty')
  pr_state=$(echo "$entry" | jq -r '.pr_state // empty')

  # Only return if cache is valid and PR is still OPEN
  if [ -n "$pr_number" ] && [ "$pr_state" = "OPEN" ] && is_cache_valid "$cached_at"; then
    echo "$pr_number"
    return 0
  fi

  return 1
}

# Write PR number to cache
write_to_cache() {
  local branch="$1"
  local pr_number="$2"
  local pr_state="$3"

  init_cache

  local cached_at
  cached_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Update the cache file atomically
  jq --arg branch "$branch" \
     --argjson pr_number "$pr_number" \
     --arg cached_at "$cached_at" \
     --arg pr_state "$pr_state" \
     --arg updated_at "$cached_at" \
     '.updated_at = $updated_at | .mappings[$branch] = {pr_number: $pr_number, cached_at: $cached_at, pr_state: $pr_state}' \
     "$CACHE_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
}

# Fetch PR number from GitHub API
fetch_from_github() {
  local branch="$1"

  # Get PR info
  local pr_info
  if ! pr_info=$(gh pr view --json number,state 2>/dev/null); then
    return 1
  fi

  local pr_number pr_state
  pr_number=$(echo "$pr_info" | jq -r '.number // empty')
  pr_state=$(echo "$pr_info" | jq -r '.state // "UNKNOWN"')

  if [ -z "$pr_number" ]; then
    return 1
  fi

  # Update cache if caching is enabled
  if [ "$USE_CACHE" = true ]; then
    write_to_cache "$branch" "$pr_number" "$pr_state"
    echo "Cached PR #$pr_number for branch '$branch'" >&2
  fi

  echo "$pr_number"
}

# Main logic
main() {
  local branch
  branch=$(get_branch_name)

  if [ -z "$branch" ]; then
    echo "Error: Not in a git repository or unable to determine branch" >&2
    exit 1
  fi

  # Try cache first (unless disabled or force refresh)
  if [ "$USE_CACHE" = true ] && [ "$FORCE_REFRESH" = false ]; then
    local cached_pr
    if cached_pr=$(read_from_cache "$branch"); then
      echo "$cached_pr"
      return 0
    fi
  fi

  # Fetch from GitHub
  local pr_number
  if pr_number=$(fetch_from_github "$branch"); then
    echo "$pr_number"
    return 0
  fi

  # No PR found
  exit 1
}

main
