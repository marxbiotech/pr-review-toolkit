#!/usr/bin/env bash
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

# Environment shorthand mapping
map_env() {
  local env="$1"
  case "$env" in
    brian)  echo "dev-brian" ;;
    ray)    echo "dev-ray" ;;
    reckie) echo "dev-reckie" ;;
    suki)   echo "dev-suki" ;;
    xin)    echo "dev-xin" ;;
    *)      echo "$env" ;;
  esac
}

# Valid environments
VALID_ENVS="staging dev-brian dev-ray dev-reckie dev-suki dev-xin preview snowiou"

validate_env() {
  local env="$1"
  for valid in $VALID_ENVS; do
    if [ "$env" = "$valid" ]; then
      return 0
    fi
  done
  return 1
}

# Check argument
if [ $# -lt 1 ]; then
  echo "Error: Missing environment argument"
  echo "Usage: $0 <environment>"
  echo "Valid environments: staging, brian, ray, reckie, suki, xin, preview, snowiou"
  exit 1
fi

ENV_INPUT="$1"
FULL_ENV=$(map_env "$ENV_INPUT")

# Validate environment
if ! validate_env "$FULL_ENV"; then
  echo "Error: Invalid environment '$ENV_INPUT'"
  echo "Valid environments: staging, brian, ray, reckie, suki, xin, preview, snowiou"
  exit 1
fi

# Get current branch
BRANCH=$(git branch --show-current)

if [ -z "$BRANCH" ]; then
  echo "Error: Not on a branch (detached HEAD?)"
  exit 1
fi

# Find PR for current branch
PR_NUMBER=$(gh pr list --head "$BRANCH" --json number --jq '.[0].number' 2>/dev/null || true)

if [ -z "$PR_NUMBER" ]; then
  echo "Error: No PR found for branch '$BRANCH'"
  echo "Create a PR first: gh pr create"
  exit 1
fi

# Add deploy comment
gh pr comment "$PR_NUMBER" --body "/deploy $FULL_ENV"
echo "✓ Triggered deployment to '$FULL_ENV' on PR #$PR_NUMBER"
