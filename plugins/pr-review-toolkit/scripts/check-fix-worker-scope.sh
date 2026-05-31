#!/bin/bash
# NOTE: This script is duplicated across two trees:
#   - scripts/check-fix-worker-scope.sh                          (authoritative)
#   - plugins/pr-review-toolkit/scripts/check-fix-worker-scope.sh (packaged copy)
# CI enforces byte+mode equality. Edit BOTH in the same commit, or sync via:
#   rsync -a --delete scripts/ plugins/pr-review-toolkit/scripts/
#
# Validate that every file changed in the working tree (tracked
# modifications + untracked additions) is in the union of fix-worker
# owned-files declared by pr-review-resolver this session.
#
# Usage: ./check-fix-worker-scope.sh [owned_file ...]
#
# Owned files are passed as arguments. Empty argument list means
# "no files should have changed"; any change will be reported.
#
# Bash 3.2 compatible (macOS default /bin/bash). Avoids associative
# arrays and mapfile; uses linear search over a saved indexed array
# for set-membership lookups (O(actual * owned), both small in practice).
#
# Handles correctly:
#   - filenames with spaces                 — NUL-delimited reads
#   - filenames with literal newline bytes  — read -d '' preserves bytes
#                                             byte-for-byte; linear compare
#                                             is byte-exact (R4-C1)
#   - non-ASCII filenames                   — core.quotePath=false keeps
#                                             paths in raw UTF-8 (matching
#                                             raw arg strings)
#   - renames                               — --no-renames forces both old
#                                             and new paths to appear so
#                                             callers must declare both
#                                             endpoints in OWNED_FILES
#   - files inside untracked directories    — -uall on git status forces
#                                             per-file enumeration so files
#                                             cannot hide behind a "dir/"
#                                             collapsed entry (R4-C2)
#
# Exit codes:
#   0 = scope OK (every changed file is in the owned set)
#   2 = unexpected files changed; report printed to stderr
#   * = pass-through rc from git on invocation failure

set -euo pipefail

# Save the expected set as a regular indexed array. Iteration uses
# `"${EXPECTED[@]+...}"` form so an empty array doesn't trip `set -u`
# on bash 3.2 (which treats `${arr[@]}` on empty arrays as unbound).
EXPECTED=("$@")

# Track unexpected paths in an indexed array (also bash 3.2 safe).
UNEXPECTED=()

# Linear membership check. Returns 0 if $1 is in EXPECTED, 1 otherwise.
# Linear scan is fine: both the owned set and the changed set are small
# in any realistic resolver session (single-digit to low-double-digit
# elements), and the comparison is byte-exact.
is_expected() {
  local needle="$1"
  local elem
  if [ "${#EXPECTED[@]}" -eq 0 ]; then
    return 1
  fi
  for elem in "${EXPECTED[@]}"; do
    if [ "$elem" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

# Tracked modifications via `git diff -z`. Each record is one path,
# NUL-terminated. `read -d ''` preserves all bytes (including embedded
# newlines) byte-for-byte, unlike `tr '\0' '\n'` which would silently
# truncate filenames containing literal newlines at the embedded byte.
#
# --no-renames forces a rename (git mv a b) to appear as deletion of `a`
# plus addition of `b`, so callers must include both endpoints in
# OWNED_FILES — otherwise the legitimate rename aborts as unexpected,
# but at least no silent escape is possible.
while IFS= read -r -d '' path; do
  [ -z "$path" ] && continue
  if ! is_expected "$path"; then
    UNEXPECTED+=("$path")
  fi
done < <(git -c core.quotePath=false diff -z --name-only --no-renames HEAD)

# Untracked entries via `git status -z --porcelain -uall`. Each record is
# the 2-char status code, a space, and the path, all NUL-terminated. The
# 3-char prefix is stripped via parameter expansion. -uall forces per-file
# enumeration: without it, files inside a pre-existing untracked directory
# collapse to a single `dir/` entry and a worker could hide arbitrary new
# files inside such a directory and bypass the scope check.
while IFS= read -r -d '' record; do
  [ -z "$record" ] && continue
  # Only `?? ` records are untracked additions; the other porcelain v1
  # status codes (M, A, D, R, C, U) for tracked files are already
  # surfaced by the git diff loop above.
  case "$record" in
    '?? '*) path="${record#?? }" ;;
    *) continue ;;
  esac
  # Strip the leading space remaining after "??" so paths like " path"
  # don't have a phantom leading space (the status format is `XY path`
  # so the space is part of the 3-char prefix).
  path="${path# }"
  [ -z "$path" ] && continue
  if ! is_expected "$path"; then
    UNEXPECTED+=("$path")
  fi
done < <(git -c core.quotePath=false status -z --porcelain -uall)

if [ "${#UNEXPECTED[@]}" -gt 0 ]; then
  echo "Unexpected files changed (not in any worker's owned set):" >&2
  for path in "${UNEXPECTED[@]}"; do
    printf '  %s\n' "$path" >&2
  done
  exit 2
fi

exit 0
