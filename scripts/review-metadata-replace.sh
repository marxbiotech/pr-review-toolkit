#!/bin/bash
# Replace the pr-review metadata block in a review comment.
#
# Usage:
#   review-metadata-replace.sh COMMENT_FILE METADATA_JSON_FILE
#   review-metadata-replace.sh --stdin --metadata-file METADATA_JSON_FILE
#
# Output: full review comment with replaced metadata block

set -euo pipefail

READ_STDIN=false
COMMENT_FILE=""
METADATA_FILE=""

while [ $# -gt 0 ]; do
  arg="$1"
  case "$arg" in
    --stdin)
      READ_STDIN=true
      ;;
    --metadata-file)
      shift
      if [ $# -eq 0 ]; then
        echo "Error: --metadata-file requires a value" >&2
        exit 2
      fi
      METADATA_FILE="$1"
      ;;
    --metadata-file=*)
      METADATA_FILE="${arg#*=}"
      ;;
    *)
      if [ -z "$COMMENT_FILE" ]; then
        COMMENT_FILE="$arg"
      elif [ -z "$METADATA_FILE" ]; then
        METADATA_FILE="$arg"
      else
        echo "Error: Unexpected argument: $arg" >&2
        exit 2
      fi
      ;;
  esac
  shift
done

if [ -z "$METADATA_FILE" ]; then
  echo "Error: metadata JSON file is required" >&2
  exit 2
fi

if [ ! -f "$METADATA_FILE" ]; then
  echo "Error: Metadata file not found: $METADATA_FILE" >&2
  exit 2
fi

if ! jq empty "$METADATA_FILE" >/dev/null 2>&1; then
  echo "Error: Metadata file is not valid JSON: $METADATA_FILE" >&2
  exit 2
fi

FORMATTED_METADATA_FILE=$(mktemp)
trap 'rm -f "$FORMATTED_METADATA_FILE"' EXIT
jq . "$METADATA_FILE" > "$FORMATTED_METADATA_FILE"

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

printf '%s\n' "$COMMENT_CONTENT" | awk -v metadata_file="$FORMATTED_METADATA_FILE" '
  /^<!-- pr-review-metadata/ {
    if (replaced) {
      print "Error: multiple pr-review metadata blocks found" > "/dev/stderr"
      exit 4
    }
    print "<!-- pr-review-metadata"
    while ((getline metadata_line < metadata_file) > 0) {
      print metadata_line
    }
    close(metadata_file)
    print "-->"
    in_meta=1
    replaced=1
    next
  }
  in_meta && /^-->$/ {
    in_meta=0
    next
  }
  in_meta {
    next
  }
  {
    print
  }
  END {
    if (in_meta) {
      print "Error: unterminated pr-review metadata block" > "/dev/stderr"
      exit 3
    }
    if (!replaced) {
      print "Error: pr-review metadata block not found" > "/dev/stderr"
      exit 3
    }
  }
'
