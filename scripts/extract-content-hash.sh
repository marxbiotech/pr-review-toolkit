#!/bin/bash
# NOTE: This script is duplicated across two trees:
#   - scripts/extract-content-hash.sh                          (authoritative)
#   - plugins/pr-review-toolkit/scripts/extract-content-hash.sh (packaged copy)
# CI enforces byte+mode equality. Edit BOTH in the same commit, or sync via:
#   rsync -a --delete scripts/ plugins/pr-review-toolkit/scripts/
#
# Extract and validate the content_hash from a PR review cache file
# for use as the CAS token in cache-write-comment.sh.
#
# Triggers cache-sync.sh recovery on missing file or malformed hash,
# and surfaces the recovery script's rc instead of silently swallowing
# recovery failures.
#
# Usage: ./extract-content-hash.sh <PR_NUMBER>
# Stdout (on success): the content hash, e.g. "sha256:abc..."
# Stderr (on recovery): a diagnostic describing the trigger
# Exit codes:
#   0 = success; valid sha256:<64hex> hash on stdout
#   2 = needs caller retry; cache-sync.sh ran successfully and the cache
#       file should now be valid, but the caller should re-invoke this
#       helper with the refreshed cache rather than trust this run's output
#   * = pass-through rc from cache-sync.sh when recovery itself failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PR_NUMBER="${1:-}"
if [ -z "$PR_NUMBER" ]; then
  echo "Error: PR number required. Usage: $0 <PR_NUMBER>" >&2
  exit 2
fi

CACHE_DIR=".pr-review-cache"
CACHE_FILE="${CACHE_DIR}/pr-${PR_NUMBER}.json"

attempt_recovery() {
  local reason="$1"
  echo "Cache content_hash unavailable (${reason}). Refreshing cache from GitHub..." >&2
  # Note: do NOT use `if ! cmd; then rc=$?; fi` here — $? after `! cmd`
  # holds the NEGATED rc (0 if cmd failed, 1 if it succeeded), not the
  # underlying cmd rc. Use `cmd || rc=$?` so the real rc is captured.
  local rc=0
  "${SCRIPT_DIR}/cache-sync.sh" "$PR_NUMBER" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "Cache recovery failed (cache-sync.sh rc=${rc}). Manual intervention required." >&2
    exit "$rc"
  fi
  # Post-recovery sanity check: a successful exit from cache-sync.sh does NOT
  # guarantee a well-formed cache (e.g. partial network failure not detected
  # by cache-sync's own checks). Validate here so the caller can't enter a
  # retry loop on a still-malformed cache.
  if [ ! -f "$CACHE_FILE" ]; then
    echo "Recovery did not produce cache file: ${CACHE_FILE}" >&2
    echo "Manual intervention required." >&2
    exit 1
  fi
  # Apply the same stderr-separation pattern as the main flow (line ~82):
  # `2>/dev/null` would swallow jq's diagnostic on a truncated/malformed
  # cache produced by a partial-network sync, making the "did not produce
  # a valid content_hash" message misleading (says "hash missing" when
  # the real problem is "JSON parse error"). Capture stderr explicitly.
  local recovered
  local recovered_err
  recovered_err=$(mktemp)
  local recovered_rc=0
  recovered=$(jq -r '.content_hash // ""' "$CACHE_FILE" 2>"$recovered_err") || recovered_rc=$?
  if [ "$recovered_rc" -ne 0 ]; then
    echo "Recovery cache exists but jq failed reading ${CACHE_FILE}: $(cat "$recovered_err")" >&2
    echo "Manual intervention required." >&2
    rm -f "$recovered_err"
    exit 1
  fi
  rm -f "$recovered_err"
  if ! [[ "$recovered" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "Recovery did not produce a valid content_hash; got '${recovered}'." >&2
    echo "Manual intervention required." >&2
    exit 1
  fi
  # Signal caller to retry the read from the now-fresh cache. We exit 2
  # rather than printing the fresh hash because the caller's surrounding
  # context (REVIEW_CONTENT etc.) is also stale and needs re-reading.
  exit 2
}

if [ ! -f "$CACHE_FILE" ]; then
  attempt_recovery "file missing: ${CACHE_FILE}"
fi

# Capture jq's stderr SEPARATELY so a future jq build that emits warnings to
# stderr on success (e.g. deprecation notes) doesn't contaminate $HASH with
# warning text. The earlier `2>&1` form would have routed any stderr-on-
# success into $HASH, breaking the sha256 regex below and triggering an
# unnecessary recovery — the same silent-misdiagnosis bug class that the
# disambiguate-stale-source.sh stderr-separation pattern closes at the
# cache-write inspection site.
JQ_ERR=$(mktemp)
trap 'rm -f "$JQ_ERR"' EXIT

jq_rc=0
HASH=$(jq -r '.content_hash // ""' "$CACHE_FILE" 2>"$JQ_ERR") || jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  attempt_recovery "jq failed reading ${CACHE_FILE}: $(cat "$JQ_ERR")"
fi

if ! [[ "$HASH" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  attempt_recovery "malformed hash: '${HASH}'"
fi

printf '%s\n' "$HASH"
