#!/bin/bash
# NOTE: This script is duplicated across two trees:
#   - scripts/check-pr-round-identifiers.sh                          (authoritative)
#   - plugins/pr-review-toolkit/scripts/check-pr-round-identifiers.sh (packaged copy)
# CI enforces byte+mode equality. Edit BOTH in the same commit, or sync via:
#   rsync -a --delete scripts/ plugins/pr-review-toolkit/scripts/
#
# Reject PR-round identifiers (R<round>-<class><number>, e.g. R7-C1) in
# committed source. Such identifiers are meaningful only inside the PR
# review thread that introduced them; once the PR is merged and squashed,
# no future maintainer knows what they refer to. Manual cleanup cycles
# have shown that audits reliably miss sibling sites across multiple
# rounds — this lint is the structural escape valve for that micro-pattern.
#
# Usage:
#   check-pr-round-identifiers.sh [path ...]
#
# Default scan paths (used when no args given) cover every committed
# source tree where PR-round identifiers could plausibly appear. The
# parameterized form is used by tests/check-pr-round-identifiers-test.sh
# to point the lint at fixture directories.
#
# Acceptable substitutes for PR-round identifiers: stable bug-class
# descriptions (e.g. "newline-in-filename truncation bug",
# "silent-misdiagnosis bug family") that don't require the reader to
# look up the original PR thread.
#
# Excluded paths: README.md (historical change-log entries reference
# R-numbers; new entries should still avoid them) and the
# .pr-review-cache/ directory (gitignored, but excluded for defense in
# depth so the lint stays robust if a cache file accidentally gets
# staged). The lint also self-excludes its own script and its test
# file, since those are the definition of the prohibition and the
# fixtures that exercise it — literal R-number strings appearing
# there are not violations.
#
# Regex notes:
#   - `(^|[^a-zA-Z])` / `([^a-zA-Z0-9]|$)` boundaries prevent matching
#     "MR3-C1" (commercial part numbers) or "R5-S4abc" (longer
#     identifiers).
#   - Class character set is `[A-Z]` (not `[CIS]`) so future round
#     classifications (e.g. blocker, question) are caught without
#     re-touching this lint.
#   - `-i` catches lowercase variants (e.g. `r7-c1`) that appear in
#     informal references.
#
# Stderr handling: an earlier inline form used `grep ... 2>/dev/null`
# which collapsed "no matches", "scan target missing", and "grep
# crashed" into the same silent success. Capture stderr to a temp file
# and branch on grep's exit code:
#   - 0 = found (fail loudly with matches AND surface grep_err if
#         non-empty — pre-fix had a silent-drop bug here).
#   - 1 = clean (success).
#   - >=2 = grep itself failed (surface its stderr and exit with grep's
#           rc rather than masking the failure as "clean").

set -euo pipefail

if [ $# -eq 0 ]; then
  # Default CI scan: every committed source path. Listed explicitly
  # rather than `.` to keep generated/vendored content (e.g. node_modules
  # if introduced) outside the scan.
  paths=(scripts/ tests/ plugins/ docs/ .github/ skills/ commands/
         .agents/ .claude-plugin/
         AGENTS.md CHANGELOG.md CLAUDE.md RELEASING.md)
else
  paths=("$@")
fi

grep_err=$(mktemp)
trap 'rm -f "$grep_err"' EXIT

set +e
grep_out=$(grep -riEn \
  --exclude=README.md \
  --exclude=check-pr-round-identifiers.sh \
  --exclude=check-pr-round-identifiers-test.sh \
  --exclude-dir=.pr-review-cache \
  '(^|[^a-zA-Z])R[0-9]+-[A-Z][0-9]+([^a-zA-Z0-9]|$)' \
  "${paths[@]}" 2>"$grep_err")
grep_rc=$?
set -e

# Defense-in-depth helper: surface any non-empty grep stderr to the
# caller regardless of which exit-code branch we took. The match-found
# branch (rc=0) previously skipped this, letting the EXIT trap's `rm`
# silently delete partial-scan diagnostics (e.g. permission-denied on
# a sibling file). Same bug-class as the rc=2 silent-drop fixed
# earlier; calling this from EVERY non-clean branch makes the
# guarantee structural rather than per-arm.
surface_grep_stderr() {
  if [ -s "$grep_err" ]; then
    echo "::warning::grep stderr during PR-round identifier scan:" >&2
    cat "$grep_err" >&2
  fi
}

case "$grep_rc" in
  0)
    echo "::error::PR-round identifiers found in source files:"
    printf '%s\n' "$grep_out"
    surface_grep_stderr
    echo "::error::These references rot after PR merge — replace with stable bug-class names"
    echo "::error::(e.g. 'newline-truncation bug', 'silent-misdiagnosis bug family')."
    exit 1
    ;;
  1)
    echo "✅ No PR-round identifiers in source files"
    ;;
  *)
    echo "::error::grep failed (rc=$grep_rc) while scanning for PR-round identifiers:" >&2
    surface_grep_stderr
    exit "$grep_rc"
    ;;
esac
