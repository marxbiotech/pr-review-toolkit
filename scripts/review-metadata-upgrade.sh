#!/bin/bash
# Upgrade pr-review metadata JSON embedded in a review comment to schema 1.1.
#
# Usage:
#   review-metadata-upgrade.sh [COMMENT_FILE] [--last-writer NAME]
#   review-metadata-upgrade.sh --stdin [--last-writer NAME]
#
# Output: upgraded metadata JSON

set -euo pipefail

READ_STDIN=false
COMMENT_FILE=""
LAST_WRITER=""

while [ $# -gt 0 ]; do
  arg="$1"
  case "$arg" in
    --stdin)
      READ_STDIN=true
      ;;
    --last-writer)
      shift
      if [ $# -eq 0 ]; then
        echo "Error: --last-writer requires a value" >&2
        exit 2
      fi
      LAST_WRITER="$1"
      ;;
    --last-writer=*)
      LAST_WRITER="${arg#*=}"
      ;;
    *)
      if [ -z "$COMMENT_FILE" ]; then
        COMMENT_FILE="$arg"
      else
        echo "Error: Unexpected argument: $arg" >&2
        exit 2
      fi
      ;;
  esac
  shift
done

if [ "$READ_STDIN" = true ]; then
  COMMENT_CONTENT=$(cat)
else
  if [ -z "$COMMENT_FILE" ]; then
    echo "Error: COMMENT_FILE required unless --stdin is used" >&2
    exit 2
  fi
  if [ ! -f "$COMMENT_FILE" ]; then
    echo "Error: Comment file not found: $COMMENT_FILE" >&2
    exit 2
  fi
  COMMENT_CONTENT=$(cat "$COMMENT_FILE")
fi

if [ -z "$COMMENT_CONTENT" ]; then
  echo "Error: Comment content is empty" >&2
  exit 2
fi

META_COUNT=$(printf '%s\n' "$COMMENT_CONTENT" | grep -c '^<!-- pr-review-metadata' || true)
if [ "$META_COUNT" -gt 1 ]; then
  echo "Error: multiple pr-review metadata blocks found" >&2
  exit 4
fi

METADATA=$(printf '%s\n' "$COMMENT_CONTENT" | awk '
  /^<!-- pr-review-metadata/ { in_meta=1; next }
  in_meta && /^-->$/ { in_meta=0; found=1; exit }
  in_meta { print }
  END { if (!found) exit 3 }
')

if [ -z "$METADATA" ]; then
  echo "Error: pr-review metadata block not found" >&2
  exit 3
fi

if ! printf '%s\n' "$METADATA" | jq empty >/dev/null 2>&1; then
  echo "Error: pr-review metadata block is not valid JSON" >&2
  exit 3
fi

META_TYPE=$(printf '%s\n' "$METADATA" | jq -r 'type')
if [ "$META_TYPE" != "object" ]; then
  echo "Error: pr-review metadata must be a JSON object, got $META_TYPE" >&2
  exit 3
fi

jq --arg last_writer "$LAST_WRITER" '
  def arr(x): if x == null then [] elif (x | type) == "array" then x else [x] end;

  . as $m
  | ($m.review_sources // {}) as $sources
  | ($sources.claude // {}) as $claude
  | ($sources.gemini // {}) as $gemini
  | ($sources.codex // {}) as $codex
  | .schema_version = "1.1"
  | .created_by = (.created_by // .skill // (if $last_writer != "" then $last_writer else "unknown" end))
  | .last_writer = (if $last_writer != "" then $last_writer else (.last_writer // .skill // .created_by // "unknown") end)
  | .skill = .last_writer
  | .review_sources = {
      claude: {
        last_reviewed_head: ($claude.last_reviewed_head // null),
        last_reviewed_at: ($claude.last_reviewed_at // null),
        agents_run: arr($claude.agents_run // $m.agents_run)
      },
      gemini: {
        consumed_comment_ids: arr($gemini.consumed_comment_ids // $m.gemini_integrated_ids),
        last_integrated_at: ($gemini.last_integrated_at // $m.gemini_integration_date // null)
      },
      codex: {
        last_reviewed_head: ($codex.last_reviewed_head // null),
        last_reviewed_at: ($codex.last_reviewed_at // null),
        posted_finding_ids: arr($codex.posted_finding_ids)
      }
    }
  | .agents_run = .review_sources.claude.agents_run
' <<< "$METADATA"
