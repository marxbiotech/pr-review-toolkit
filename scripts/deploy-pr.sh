#!/bin/bash
#
# Deploy to environment by commenting on the current branch's PR
#
# Usage: ./scripts/deploy-pr.sh <environment>
#
# Environments:
#   staging, preview, snowiou
#   brian (→ dev-brian), ray (→ dev-ray), reckie (→ dev-reckie),
#   suki (→ dev-suki), xin (→ dev-xin)

set -euo pipefail

# Design Decision: No explicit CLI availability checks for git/gh
# Rationale: Target users are developers who already have these tools installed.
# "command not found" errors are sufficiently clear for this audience.
# @see PR #1 review comment

# Resolve and validate environment (maps shorthand and validates)
# Returns: full environment name on stdout, exit code 0 if valid, 1 if invalid
resolve_env() {
  local env="$1"
  case "$env" in
    # Shorthands
    brian)  echo "dev-brian" ;;
    ray)    echo "dev-ray" ;;
    reckie) echo "dev-reckie" ;;
    suki)   echo "dev-suki" ;;
    xin)    echo "dev-xin" ;;
    # Full names (valid environments)
    staging|dev-brian|dev-ray|dev-reckie|dev-suki|dev-xin|preview|snowiou)
      echo "$env"
      ;;
    # Invalid
    *)
      return 1
      ;;
  esac
}

# Check argument
if [ $# -lt 1 ]; then
  echo "Error: Missing environment argument" >&2
  echo "Usage: $0 <environment>" >&2
  echo "Valid environments: staging, brian, ray, reckie, suki, xin, preview, snowiou" >&2
  exit 1
fi

ENV_INPUT="$1"

# Resolve and validate environment
if ! FULL_ENV=$(resolve_env "$ENV_INPUT"); then
  echo "Error: Invalid environment '$ENV_INPUT'" >&2
  echo "Valid environments: staging, brian, ray, reckie, suki, xin, preview, snowiou" >&2
  exit 1
fi

# Get current branch
BRANCH=$(git branch --show-current)

if [ -z "$BRANCH" ]; then
  echo "Error: Not on a branch (detached HEAD?)" >&2
  exit 1
fi

# Find PR for current branch
PR_OUTPUT=$(gh pr list --head "$BRANCH" --json number --jq '.[0].number' 2>&1) || {
  echo "Error: Failed to query GitHub for PRs on branch '$BRANCH'" >&2
  echo "Details: $PR_OUTPUT" >&2
  exit 1
}
PR_NUMBER="$PR_OUTPUT"

if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" == "null" ]; then
  echo "Error: No PR found for branch '$BRANCH'" >&2
  echo "Create a PR first: gh pr create" >&2
  exit 1
fi

# Add deploy comment
if ! gh pr comment "$PR_NUMBER" --body "/deploy $FULL_ENV"; then
  echo "Error: Failed to post deploy comment on PR #$PR_NUMBER" >&2
  echo "The deployment was NOT triggered." >&2
  exit 1
fi
echo "✓ Triggered deployment to '$FULL_ENV' on PR #$PR_NUMBER"
