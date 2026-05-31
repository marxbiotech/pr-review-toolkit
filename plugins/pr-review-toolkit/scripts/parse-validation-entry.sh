#!/bin/bash
# NOTE: This script is duplicated across two trees:
#   - scripts/parse-validation-entry.sh                          (authoritative)
#   - plugins/pr-review-toolkit/scripts/parse-validation-entry.sh (packaged copy)
# CI enforces byte+mode equality. Edit BOTH in the same commit, or sync via:
#   rsync -a --delete scripts/ plugins/pr-review-toolkit/scripts/
#
# Parse a single `Validation:` entry line from a codex-fix-worker
# Output Contract block (see codex-fix-worker/SKILL.md).
#
# Entry shapes (exactly one of):
#   - <command> -- exit <N>       — a real validation command and its rc
#   - none possible: <reason>     — explicit "no validation applies"
#
# The separator in form (1) is the ASCII double-dash ` -- ` (space + two
# hyphens + space). Em-dash and single-hyphen forms are rejected.
# Commands legitimately containing the substring ` -- ` must be quoted
# (per the codex-fix-worker contract).
#
# Usage: ./parse-validation-entry.sh <entry>
# Stdin: not consumed.
# Stdout (per shape):
#   form 1 ("- cmd -- exit N"): two lines — first the exit code, second
#                               the command text.
#   form 2 ("- none possible: reason"): two lines — `none-possible` literal,
#                                       then the reason text.
# Exit codes:
#   0 = recognized shape; stdout populated as above.
#   2 = unrecognized shape (malformed entry; stderr describes mismatch).
#
# Intended consumer: pr-review-resolver step 8, which iterates over each
# `Validation:` line in a fix-worker output and uses this script to
# decide success-eligibility (every entry must be `-- exit 0` or
# `none possible: <reason>` for the resolver to honor `Status: success`).

set -euo pipefail

ENTRY="${1:-}"
if [ -z "$ENTRY" ]; then
  echo "Error: validation entry required. Usage: $0 '<entry>'" >&2
  exit 2
fi

# Form 2: `- none possible: <reason>` (with or without leading `- `).
# Strip leading `- ` if present.
case "$ENTRY" in
  '- '*) stripped="${ENTRY#- }" ;;
  *) stripped="$ENTRY" ;;
esac

case "$stripped" in
  'none possible:'*)
    reason="${stripped#none possible:}"
    # Trim one leading space if present.
    reason="${reason# }"
    if [ -z "$reason" ]; then
      echo "Error: 'none possible:' requires a non-empty reason" >&2
      exit 2
    fi
    printf 'none-possible\n%s\n' "$reason"
    exit 0
    ;;
esac

# Form 1: `<command> -- exit <N>` (regex: cmd, then literal ` -- exit `,
# then signed integer).
# Use bash regex to extract cmd and N.
if [[ "$stripped" =~ ^(.*)\ --\ exit\ (-?[0-9]+)$ ]]; then
  cmd="${BASH_REMATCH[1]}"
  rc="${BASH_REMATCH[2]}"
  if [ -z "$cmd" ]; then
    echo "Error: empty command before ' -- exit <N>'" >&2
    exit 2
  fi
  printf '%s\n%s\n' "$rc" "$cmd"
  exit 0
fi

echo "Error: unrecognized validation entry shape: '$ENTRY'" >&2
echo "Expected one of:" >&2
echo "  '<command> -- exit <N>'   (ASCII double-dash separator)" >&2
echo "  'none possible: <reason>' (with reason explaining why)" >&2
exit 2
