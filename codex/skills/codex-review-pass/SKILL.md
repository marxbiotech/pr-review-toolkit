---
name: codex-review-pass
description: Use when asked to run a Codex PR review pass, create the first canonical PR review comment, append Codex findings to an existing pr-review-toolkit comment, or participate in the PR review loop using .pr-review-cache/pr-#.json as the only review state contract.
---

# Codex Review Pass

Run a Codex second-pass PR review and record findings in the canonical pr-review-toolkit review comment.

## Contract

Use `.pr-review-cache/pr-#.json` as the only PR review state file. Do not create extra Codex cache files, extra PR comments, commits, pushes, or direct `gh api` comment updates.

Find the toolkit root in this order:

1. Use `PR_REVIEW_TOOLKIT_ROOT` when set.
2. If this skill is installed inside the toolkit repo, derive the root from the skill path.
3. Stop and ask the dev agent for `PR_REVIEW_TOOLKIT_ROOT`.

Use only these scripts for review state:

```bash
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/get-pr-number.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-replace.sh"
```

## Workflow

1. Get the PR number with `get-pr-number.sh`.
2. Call `cache-read-comment.sh "$PR_NUMBER"` using the bounded `set +e` / exit-code capture idiom below. Do NOT collapse the exit codes with `|| true` — exit `1` (real error) and exit `2` (bootstrap) must be handled distinctly.

   ```bash
   set +e
   REVIEW_CONTENT=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh" "$PR_NUMBER")
   rc=$?
   set -e

   case $rc in
     0) MODE=append ;;       # cache populated; proceed to step 3 to capture .content_hash
     2) MODE=bootstrap ;;    # no canonical comment exists; skip step 3 entirely
     *) echo "cache-read-comment.sh failed with exit $rc" >&2; exit "$rc" ;;
   esac
   ```
3. Only in append mode: read `.pr-review-cache/pr-${PR_NUMBER}.json` and save `.content_hash` as `EXPECTED_CONTENT_HASH`. (Bootstrap mode skips this step entirely.)
4. Review the PR diff and current working tree. Focus on correctness, test gaps, cross-file consistency, error handling, and simplification after fixes.
5. Produce only actionable findings that are not already present in the comment.
6. Write the updated comment through `cache-write-comment.sh --stdin "$PR_NUMBER" --expected-content-hash "$EXPECTED_CONTENT_HASH"` when an expected hash exists. If there was no cache before bootstrap, omit the expected hash.
7. If the script exits `4`, re-read the comment, merge your update into the newer content, and retry once. If the retry also exits `4`, stop and report `CAS conflict: another writer holds the lock` along with the current `content_hash` for the dev agent to investigate. Do not retry beyond the second attempt.

## Metadata Rules

Use comment metadata schema `1.1` inside `<!-- pr-review-metadata ... -->`. Do not change the cache envelope schema.

- `created_by`: first review producer that created the canonical comment
- `last_writer`: `codex-review-pass`
- `skill`: legacy field; bootstrap sets it to `codex-review-pass`
- `review_sources.codex.last_reviewed_head`: current HEAD SHA
- `review_sources.codex.last_reviewed_at`: UTC timestamp
- `review_sources.codex.posted_finding_ids`: stable Codex finding IDs
- `review_sources.claude.agents_run`: empty array `[]` on Codex bootstrap (no Claude agents ran)
- top-level `agents_run`: dual-write mirror of `review_sources.claude.agents_run` for Phase-2 backward compat — set to `[]` on Codex bootstrap. Will be removed in a future release.

Upgrade older metadata before writing with:

```bash
METADATA_JSON=$(printf '%s\n' "$REVIEW_CONTENT" | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh" --stdin --last-writer codex-review-pass)
```

After editing metadata JSON, replace the hidden block without touching issue sections:

```bash
# Set up a temp file for the modified metadata JSON.
# (If this code block already declares its own trap, extend it instead of adding a second line.)
METADATA_FILE=$(mktemp)
trap 'rm -f "$METADATA_FILE"' EXIT

# Write the edited metadata JSON to the temp file.
printf '%s' "$METADATA_JSON" > "$METADATA_FILE"

# Replace the metadata block in the comment.
UPDATED_CONTENT=$(printf '%s\n' "$REVIEW_CONTENT" | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-replace.sh" --stdin --metadata-file "$METADATA_FILE")
```

Preserve Claude and Gemini sections, metadata, and existing issue statuses.

`review_round` is PR-global. Increment it only when this pass adds new findings. Empty passes update `last_reviewed_head` and `last_reviewed_at` without incrementing.

`Reviewer Sources` is derived in this fixed order: `Claude, Gemini, Codex`, including only sources that have participated.

## Finding Format

Use this details format:

```markdown
<details>
<summary><b>N. ⚠️ [Codex] Issue title</b></summary>

**Source:** Codex
**File:** `path/to/file.ts:42`

**Problem:** ...

**Fix:** ...

</details>
```

Finding IDs are best-effort and should not rely only on line numbers:

```text
codex:<file>:<symbol-or-nearest-heading>:<diagnostic-kind>:<snippet-hash>
```

If a duplicate slips through, mark it as duplicate only when the dev agent asks; otherwise report the duplicate risk.

## Bootstrap Mode

When no canonical comment exists, create the initial PR review comment with the standard `<!-- pr-review-metadata` marker, summary table, Critical Issues, Important Issues, Suggestions, Strengths, and Action Plan sections. Publish through `cache-write-comment.sh --stdin`.

Bootstrap must not run concurrently with another producer. If duplicate canonical comments are detected, stop and ask the dev agent to keep only the `.pr-review-cache/pr-#.json` `source_comment_id` comment.

## Canonical Taxonomy

Actionable findings (anything labelled "Severity: Important", "before-merge",
🔴 Critical, 🟡 Important, or 💡 Suggestion) MUST be appended into the existing
canonical sections — `### 🔴 Critical Issues`, `### 🟡 Important Issues`, or
`### 💡 Suggestions` — and counted in the Summary table by incrementing
`issues.{critical|important|suggestions}.total`. Renumber existing items in the
section so the new findings sit at the end with the next sequential numbers.

A separate `### 🟠 Codex Follow-up Notes` block is allowed ONLY for non-canonical
content that does not change merge status: validation-run confirmations,
environmental observations, design rationale, or audit trails. Anything that
needs to be acted on before merge is by definition canonical.

This rule prevents the Summary table from drifting out of sync with the actual
PR review state and lets `pr-review-resolver` discover all unresolved items
through the canonical `⚠️` / `🔴` markers in the Critical / Important /
Suggestions sections.

## Append Mode

When a comment exists:

- Preserve existing `[Gemini]`, `[Codex]`, and untagged Claude issues.
- Treat untagged issues as Claude issues.
- Add new Codex findings to the appropriate severity section.
- Update summary counts, metadata timestamps, `last_writer`, and `review_sources.codex`.
- Do not change existing issue statuses unless the dev agent explicitly requested it.
