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

# Tolerate trailing whitespace (common from markdown editors that strip
# nothing on save). Leading whitespace is preserved because indentation
# inside a list-item continuation may be semantically meaningful.
ENTRY="${ENTRY%"${ENTRY##*[![:space:]]}"}"

if [ -z "$ENTRY" ]; then
  echo "Error: validation entry is whitespace-only" >&2
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
    # Reject whitespace-only reasons (e.g. `none possible:    `). The
    # `[ -z ]` check alone passes anything non-empty; we need to verify
    # there's at least one non-whitespace byte in the reason.
    case "$reason" in
      *[![:space:]]*) ;;
      *)
        echo "Error: 'none possible:' requires a non-whitespace reason" >&2
        exit 2
        ;;
    esac
    printf 'none-possible\n%s\n' "$reason"
    exit 0
    ;;
esac

# Form 1: `<command> -- exit <N>` (regex: cmd, then literal ` -- exit `,
# then signed integer).
#
# Reject adversarial laundering — `failing-cmd -- exit 1 -- exit 0`
# would, under the greedy `.*` regex, parse as cmd=`failing-cmd -- exit
# 1` with rc=0, silently laundering the worker's failure through the
# safety net the parser was extracted to enforce. Count occurrences
# of ` -- exit ` first; reject if more than one. Workers with
# legitimate commands containing ` -- exit ` mid-string must quote
# them so only one boundary survives at the entry's tail.
# Count boundaries across the ENTIRE input (including any embedded
# newlines), not per-record. A previous form had `print count` inside
# the main `{ }` block, so a multi-line entry produced one count per
# line (e.g. "1\n1") instead of a single integer. The downstream
# `[ ... -gt 1 ]` arithmetic test then crashed with `integer expression
# expected`, but because it lived inside an `if` condition `set -e` did
# NOT abort — control fell through to the form-1 regex, which greedily
# matched the final ` -- exit <N>$` and laundered the worker's earlier
# failure into rc=0. `END { print count }` ensures the count is exactly
# one integer regardless of how many lines the input spans, so the
# `-gt 1` check correctly rejects multi-line laundering as well as the
# single-line `a -- exit 1 -- exit 0` shape.
boundary_count=$(printf '%s' "$stripped" | awk -v p=' -- exit ' '
  BEGIN { count = 0 }
  {
    pos = 1
    while ((found = index(substr($0, pos), p)) > 0) {
      count++
      pos = pos + found + length(p) - 1
    }
  }
  END { print count }
')
# Shape guard: the arithmetic test below lives inside an `if`, so a
# non-integer boundary_count would crash with "integer expression
# expected" WITHOUT aborting under set -e — exactly the laundering
# channel the awk `END { print count }` placement was just fixed to
# close. A future refactor that re-introduces per-record `print` (or
# any other shape regression) must NOT silently fall through to the
# form-1 regex. Reject any non-single-non-negative-integer shape
# loudly before the arithmetic test consumes it.
case "$boundary_count" in
  ''|*[!0-9]*)
    echo "Error: internal — boundary_count must be a single non-negative integer (got: '${boundary_count}')" >&2
    exit 2
    ;;
esac
if [ "$boundary_count" -gt 1 ]; then
  echo "Error: validation entry contains multiple ' -- exit ' boundaries (got ${boundary_count})" >&2
  echo "       quote commands that legitimately contain ' -- exit ' so only the tail boundary survives" >&2
  exit 2
fi

if [[ "$stripped" =~ ^(.*)\ --\ exit\ (-?[0-9]+)$ ]]; then
  cmd="${BASH_REMATCH[1]}"
  rc="${BASH_REMATCH[2]}"
  # Reject empty AND whitespace-only commands. `[ -z "$cmd" ]` alone
  # passes a cmd like `   ` (three spaces) which is meaningless.
  case "$cmd" in
    *[![:space:]]*) ;;
    *)
      echo "Error: command before ' -- exit <N>' is empty or whitespace-only" >&2
      exit 2
      ;;
  esac
  printf '%s\n%s\n' "$rc" "$cmd"
  exit 0
fi

echo "Error: unrecognized validation entry shape: '$ENTRY'" >&2
echo "Expected one of:" >&2
echo "  '<command> -- exit <N>'   (ASCII double-dash separator)" >&2
echo "  'none possible: <reason>' (with reason explaining why)" >&2
exit 2
