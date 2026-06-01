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
#                                             is byte-exact. Earlier
#                                             `tr '\0' '\n'`-based form
#                                             silently truncated such names.
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
#                                             collapsed entry. Without -uall,
#                                             a worker could drop arbitrary
#                                             files inside a pre-existing
#                                             untracked dir and bypass scope.
#   - .gitignored writes by fix-workers      — --ignored=traditional surfaces
#                                             ignored files in the porcelain
#                                             output as `!! path`. Without
#                                             this, a worker could write
#                                             *.log, node_modules/, .env,
#                                             secrets/ etc. and bypass scope
#                                             entirely.
#
# Exit codes:
#   0 = scope OK (every changed file is in the owned set)
#   2 = unexpected files changed; report printed to stderr
#   * = pass-through rc from git on invocation failure

set -euo pipefail

# Save the expected set as a regular indexed array. Iteration is
# guarded by an explicit length check in `is_expected()` below
# (`[ "${#EXPECTED[@]}" -eq 0 ] && return 1`) rather than relying on
# `"${EXPECTED[@]+...}"` expansion — the explicit form makes the
# empty-case behavior immediately obvious at the function entry point.
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
#
# We capture git output to a temp file first so git's rc is checked
# explicitly. Process substitution (`< <(git ...)`) runs git in a
# subshell whose rc is NOT seen by the outer `set -euo pipefail` — a
# git failure (not-a-git-repo, corrupt .git, index.lock, etc.) would
# otherwise be silently swallowed and the script would exit 0 with
# zero output, telling the resolver "scope OK" when git never ran.
# Pinned by test case 14.
TRACKED_TMP=$(mktemp)
UNTRACKED_TMP=$(mktemp)
GIT_ERR=$(mktemp)
trap 'rm -f "$TRACKED_TMP" "$UNTRACKED_TMP" "$GIT_ERR"' EXIT

# Note: do NOT use `if ! cmd; then rc=$?; fi` — $? after `! cmd` holds the
# NEGATED rc (0 if cmd failed, 1 if it succeeded), not the underlying cmd rc.
# Use the `cmd || rc=$?` form so the real rc is captured. Same lesson as
# extract-content-hash.sh:41-43.
#
# Capture git's stderr SEPARATELY (not via `> $TMP 2>&1`). Under env switches
# like GIT_TRACE=1 / GIT_TRACE_PERFORMANCE / GIT_CURL_VERBOSE / advice.*,
# git emits trace lines to stderr even on successful invocations. Merging
# stderr into the path-stream file would make the NUL-delimited path-reader
# parse trace lines AS paths, producing diagnostic output full of git
# internals. Same lesson as extract-content-hash.sh:82-88 and
# disambiguate-stale-source.sh:45-50 (the jq stderr-on-success fix).
# Pinned by test case 18.
git_rc=0
git -c core.quotePath=false diff -z --name-only --no-renames HEAD > "$TRACKED_TMP" 2>"$GIT_ERR" || git_rc=$?
if [ "$git_rc" -ne 0 ]; then
  echo "check-fix-worker-scope: git diff failed (rc=$git_rc); cannot validate scope" >&2
  cat "$GIT_ERR" >&2
  exit "$git_rc"
fi

while IFS= read -r -d '' path; do
  [ -z "$path" ] && continue
  if ! is_expected "$path"; then
    UNEXPECTED+=("$path")
  fi
done < "$TRACKED_TMP"

# Untracked entries via `git status -z --porcelain -uall`. Each record is
# the 2-char status code, a space, and the path, all NUL-terminated. The
# 3-char prefix is stripped via parameter expansion. -uall forces per-file
# enumeration: without it, files inside a pre-existing untracked directory
# collapse to a single `dir/` entry and a worker could hide arbitrary new
# files inside such a directory and bypass the scope check.
# Same rc-capture + separate-stderr pattern for git status as for git diff above.
# --ignored=traditional surfaces gitignored files as `!! path` records
# so a fix-worker cannot escape scope by writing files that match
# common gitignore patterns (*.log, node_modules/*, .env, secrets/, ...).
# Truncate $GIT_ERR before the second invocation so its contents are
# scoped to this command.
: > "$GIT_ERR"
git_rc=0
git -c core.quotePath=false status -z --porcelain -uall --ignored=traditional > "$UNTRACKED_TMP" 2>"$GIT_ERR" || git_rc=$?
if [ "$git_rc" -ne 0 ]; then
  echo "check-fix-worker-scope: git status failed (rc=$git_rc); cannot validate scope" >&2
  cat "$GIT_ERR" >&2
  exit "$git_rc"
fi

while IFS= read -r -d '' record; do
  [ -z "$record" ] && continue
  # Untracked additions are `?? path`, gitignored writes are `!! path`.
  # The other porcelain v1 status codes (M, A, D, R, C, U) for tracked
  # files are already surfaced by the git diff loop above.
  #
  # The 3-char prefix is exactly XY + 1 space. `${record#???}` would
  # also work but the explicit case + #?? form documents the format.
  # DO NOT add a further `${path# }` strip — that would silently
  # corrupt filenames that legitimately start with a space (e.g.
  # ` leading.txt` would become `leading.txt` and a worker could
  # bypass scope check by declaring the no-leading-space form as
  # owned). Pinned by test case 13.
  case "$record" in
    '?? '*) path="${record#?? }" ;;
    '!! '*) path="${record#!! }" ;;
    *) continue ;;
  esac
  [ -z "$path" ] && continue
  if ! is_expected "$path"; then
    UNEXPECTED+=("$path")
  fi
done < "$UNTRACKED_TMP"

if [ "${#UNEXPECTED[@]}" -gt 0 ]; then
  echo "Unexpected files changed (not in any worker's owned set):" >&2
  for path in "${UNEXPECTED[@]}"; do
    printf '  %s\n' "$path" >&2
  done
  exit 2
fi

exit 0
