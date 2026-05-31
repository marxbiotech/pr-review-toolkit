#!/bin/bash
# NOTE: This script is duplicated across two trees:
#   - scripts/disambiguate-stale-source.sh                          (authoritative)
#   - plugins/pr-review-toolkit/scripts/disambiguate-stale-source.sh (packaged copy)
# CI enforces byte+mode equality. Edit BOTH in the same commit, or sync via:
#   rsync -a --delete scripts/ plugins/pr-review-toolkit/scripts/
#
# Disambiguate cache-write-comment.sh exit code 1 by inspecting the
# stale_source_id flag on the PR cache file, then print appropriate
# recovery guidance to stderr.
#
# cache-write-comment.sh exit 1 covers two distinct failure modes
# (see cache-write-comment.sh:22-25):
#   (a) GitHub sync failed but local cache is up to date
#   (b) Post-sync cache repair failed (stale_source_id flag set)
# Each mode has a different recovery command.
#
# Usage: ./disambiguate-stale-source.sh <PR_NUMBER>
# Exit codes:
#   1  = disambiguation succeeded; stderr contains the recovery guidance
#        appropriate to whichever exit-1 cause fired (sync-failed vs
#        stale-source-id-repair-failed). This is the "nominal" outcome —
#        the helper was invoked from the exit-1 branch of a caller, and
#        it propagates exit 1 to keep caller flow explicit.
#   10 = cannot disambiguate (cache file missing or malformed JSON);
#        stderr contains a "manual intervention required" diagnostic.
#        Downstream tooling can distinguish 1 (nominal advice ready)
#        from 10 (investigation required).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PR_NUMBER="${1:-}"
if [ -z "$PR_NUMBER" ]; then
  echo "Error: PR number required. Usage: $0 <PR_NUMBER>" >&2
  exit 1
fi

CACHE_DIR=".pr-review-cache"
CACHE_FILE="${CACHE_DIR}/pr-${PR_NUMBER}.json"

if [ ! -f "$CACHE_FILE" ]; then
  echo "Cache file vanished between write and post-write inspection: $CACHE_FILE" >&2
  echo "Cannot disambiguate exit 1 cause without the cache envelope. Investigate manually." >&2
  exit 10
fi

# Capture jq's stderr SEPARATELY so a future jq build that emits warnings to
# stderr on success (e.g. deprecation notes) doesn't contaminate $STALE.
# The earlier `2>&1` form would have routed any stderr-on-success into
# $STALE, causing `[ "$STALE" = "true" ]` to misroute to the wrong branch —
# exactly the silent-misdiagnosis class this script was extracted to prevent.
JQ_ERR=$(mktemp)
trap 'rm -f "$JQ_ERR"' EXIT

jq_rc=0
STALE=$(jq -r '.stale_source_id // false' "$CACHE_FILE" 2>"$JQ_ERR") || jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  echo "jq failed reading $CACHE_FILE: $(cat "$JQ_ERR")" >&2
  echo "Cannot disambiguate exit 1 cause; the cache envelope may be malformed." >&2
  exit 10
fi

if [ "$STALE" = "true" ]; then
  echo "Post-sync cache repair failed; the source_comment_id placeholder was not updated." >&2
  echo "Recover with: ${SCRIPT_DIR}/cache-sync.sh \"$PR_NUMBER\"" >&2
  echo "(This re-fetches the canonical comment from GitHub and repopulates the cache envelope.)" >&2
else
  echo "GitHub sync failed but local cache is up to date." >&2
  echo "Retry the GitHub push with: ${SCRIPT_DIR}/cache-write-comment.sh --sync-from-cache \"$PR_NUMBER\"" >&2
fi

exit 1
