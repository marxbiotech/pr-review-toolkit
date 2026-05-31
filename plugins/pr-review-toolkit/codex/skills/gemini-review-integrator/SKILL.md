---
name: gemini-review-integrator
description: Use when asked to integrate, merge, sync, or add Gemini Code Assist review comments into the canonical pr-review-toolkit PR review comment. This Codex skill fetches Gemini inline comments, filters outdated or already-integrated comments, appends new Gemini findings, and writes through .pr-review-cache/pr-#.json.
---

# Gemini Review Integrator

Integrate Gemini Code Assist inline review comments into the canonical pr-review-toolkit PR review comment.

## Contract

Use `.pr-review-cache/pr-#.json` as the only PR review state file. Do not create extra cache files or extra PR comments. Do not commit, push, merge, or directly call `gh api` to update the canonical review comment.

This skill integrates external Gemini feedback only. It is not a review producer, resolver, or fixer:

- It does not run `codex-review-pass`.
- It does not ask the user to resolve findings.
- It does not modify source files.
- It preserves Claude, Codex, and existing Gemini issues.

Find the toolkit root in this order:

1. Use `PR_REVIEW_TOOLKIT_ROOT` when set. This is the supported path.
2. If `PR_REVIEW_TOOLKIT_ROOT` is unset, derive the packaged plugin root from the skill path. This SKILL.md lives at `<root>/codex/skills/<skill-name>/SKILL.md`, so `<root>` is exactly three levels up. Ensure `SKILL_PATH` is set in the environment to the absolute path of this SKILL.md before running the snippet:

   ```bash
   : "${SKILL_PATH:?SKILL_PATH must be set to the absolute path of this SKILL.md}"
   PR_REVIEW_TOOLKIT_ROOT="$(cd "$(dirname "$SKILL_PATH")/../../.." && pwd)"
   ```

   Verify both `<root>/.codex-plugin/plugin.json` and `<root>/scripts/cache-write-comment.sh` exist. If either is missing, treat derivation as failed and proceed to step 3.
3. Stop and ask the dev agent for `PR_REVIEW_TOOLKIT_ROOT`.

Canonicalize the root before using helper scripts:

```bash
PR_REVIEW_TOOLKIT_ROOT="$(cd "$PR_REVIEW_TOOLKIT_ROOT" && pwd)"
```

Use only these scripts for review state:

```bash
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/get-pr-number.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/find-review-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/fetch-gemini-comments.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-replace.sh"
```

Before running the workflow, verify these helper scripts are executable and `scripts/lib/common.sh` is readable.

## Workflow

1. Get the PR number with `get-pr-number.sh`.
2. Verify a canonical review comment exists with `find-review-comment.sh "$PR_NUMBER"`. If none exists, tell the user to run `pr-review-and-document` first.
3. Read the canonical review comment with `cache-read-comment.sh "$PR_NUMBER"`:

   ```bash
   set +e
   EXISTING_CONTENT=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh" "$PR_NUMBER")
   rc=$?
   set -e

   case $rc in
     0) ;;
     2) echo "No canonical review comment found. Run pr-review-and-document first." >&2; exit 2 ;;
     *) echo "cache-read-comment.sh failed with exit $rc" >&2; exit "$rc" ;;
   esac
   ```

4. Read `.pr-review-cache/pr-${PR_NUMBER}.json` and save `.content_hash` as `EXPECTED_CONTENT_HASH`.
5. Fetch Gemini comments:

   ```bash
   GEMINI_COMMENTS=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/fetch-gemini-comments.sh" "$PR_NUMBER")
   ```

6. Filter comments:
   - Exclude `is_outdated: true`.
   - Prefer existing metadata `review_sources.gemini.consumed_comment_ids`.
   - Fall back to legacy `gemini_integrated_ids`.
   - Exclude IDs already consumed.
7. Categorize new Gemini comments:

   | Gemini priority | Category |
   |---|---|
   | `high` + `is_security` | `critical` |
   | `high` | `important` |
   | `medium` + `is_security` | `important` |
   | `medium` | `suggestion` |
   | `low` | `suggestion` |

8. Format each new Gemini issue:

   ```markdown
   <details>
   <summary><b>N. ⚠️ [Gemini] Issue title</b></summary>

   **Source:** Gemini Code Assist
   **File:** `path/to/file.ts:42`
   **Gemini Comment ID:** `123456789`

   **Problem:** ...

   **Suggested Fix:**
   ```suggestion
   code here
   ```

   </details>
   ```

   Preserve Gemini's suggestion block when present. Keep content concise enough that the final PR comment stays below GitHub limits.
9. Insert new Gemini issues into the canonical severity sections:
   - `### 🔴 Critical Issues`
   - `### 🟡 Important Issues`
   - `### 💡 Suggestions`
10. Renumber affected issue sections and update summary counts. Preserve existing issue statuses.
11. Upgrade metadata to schema `1.1`:

   ```bash
   METADATA_JSON=$(printf '%s\n' "$EXISTING_CONTENT" | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh" --stdin --last-writer gemini-review-integrator)
   ```

12. Dual-write Gemini metadata during the compatibility window:
   - Add newly consumed integer IDs to `review_sources.gemini.consumed_comment_ids`.
   - Add the same IDs to legacy `gemini_integrated_ids`.
   - Set both `review_sources.gemini.last_integrated_at` and legacy `gemini_integration_date` to the current UTC timestamp.
   - Set `last_writer` / `skill` as appropriate for `gemini-review-integrator`.
   - Preserve `review_sources.codex`, `review_sources.claude`, `[Codex]` issues, and untagged Claude issues.
   - Keep `review_round` unchanged. Gemini integration is not a review producer.
13. Replace the hidden metadata block with `review-metadata-replace.sh`.
14. Write through `cache-write-comment.sh --stdin "$PR_NUMBER" --expected-content-hash "$EXPECTED_CONTENT_HASH"`.
15. If `cache-write-comment.sh` exits `4`, re-read the latest comment, merge only the new Gemini integrations, and retry once. If it still exits `4`, report the CAS conflict and stop.

## Gemini Comment Handling

`fetch-gemini-comments.sh` returns JSON entries with:

```json
{
  "id": 123456789,
  "priority": "high",
  "is_security": false,
  "is_outdated": false,
  "file": "path/to/file.ts",
  "line": 42,
  "body": "full comment body",
  "suggestion": "code suggestion if any",
  "created_at": "2026-01-26T10:00:00Z"
}
```

Outdated comments have `is_outdated: true` and must be skipped because the code has changed. ID-based deduplication is the source of truth for repeated integration runs.

## Status Indicators

New Gemini issues start as `⚠️` pending review. Later resolver runs may mark them:

- `✅ Fixed`
- `⏭️ Deferred`
- `⏭️ N/A`
- `⏭️ Duplicate`
- `🔴` escalated/blocking

## Output Contract

End with:

```text
Gemini Review Integration Complete:
- PR: #123
- Found Gemini comments: X
- Outdated skipped: Y
- Already integrated skipped: Z
- Newly integrated: W
  - Critical: A
  - Important: B
  - Suggestions: C
- Comment URL: ...

Review state:
- Cache: .pr-review-cache/pr-123.json
- Metadata schema: 1.1
- review_round: unchanged
```

If there are no new Gemini comments, report that the canonical review comment is already up to date and do not rewrite it unless metadata migration is explicitly needed.
