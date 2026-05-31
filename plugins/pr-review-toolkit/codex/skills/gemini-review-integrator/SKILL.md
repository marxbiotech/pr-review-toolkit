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
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/fetch-gemini-comments.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-sync.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/extract-content-hash.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/disambiguate-stale-source.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-replace.sh"
```

Before running the workflow, verify these helper scripts are executable and `scripts/lib/common.sh` is readable.

## Workflow

1. Get the PR number with `get-pr-number.sh`.
2. Read the canonical review comment with `cache-read-comment.sh "$PR_NUMBER"`:

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

   `cache-read-comment.sh` exits `2` if no canonical comment exists — there is no need for a separate `find-review-comment.sh` precheck (it would return empty stdout with rc=0 and silently look like success).
3. Extract the cache `content_hash` for CAS via the shared helper. The helper does file-existence check, jq read with rc capture, regex validation, and triggers `cache-sync.sh` on any failure (with rc propagation and post-recovery validation):

   ```bash
   set +e
   EXPECTED_CONTENT_HASH=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/extract-content-hash.sh" "$PR_NUMBER")
   rc=$?
   set -e

   case $rc in
     0) ;;
     2) echo "Cache was refreshed; re-read EXISTING_CONTENT and retry from Step 2." >&2; exit 2 ;;
     *) exit "$rc" ;;
   esac
   ```

   Unit-tested in `tests/extract-content-hash-test.sh`.
4. Fetch Gemini comments with explicit error handling. The script can fail for several reasons (gh auth expired, GitHub 5xx, network timeout, malformed PR) — collapsing those into "no Gemini comments" silently masks integration failures:

   ```bash
   set +e
   GEMINI_RAW=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/fetch-gemini-comments.sh" "$PR_NUMBER")
   gemini_rc=$?
   set -e

   if [ "$gemini_rc" -ne 0 ]; then
     echo "Error: fetch-gemini-comments.sh failed (rc=$gemini_rc). Stopping integration; the canonical comment is unchanged." >&2
     exit "$gemini_rc"
   fi

   if ! printf '%s' "$GEMINI_RAW" | jq -e 'type == "array"' >/dev/null 2>&1; then
     echo "Error: fetch-gemini-comments.sh returned non-array JSON. Stopping integration." >&2
     exit 2
   fi

   GEMINI_COMMENTS="$GEMINI_RAW"
   ```

   An empty array (`[]`) is a valid "no Gemini comments yet" result and must be reported distinctly from a fetch failure.
5. Filter comments:
   - Exclude `is_outdated: true`.
   - Prefer existing metadata `review_sources.gemini.consumed_comment_ids`.
   - Fall back to legacy `gemini_integrated_ids`.
   - Exclude IDs already consumed.
6. Categorize new Gemini comments:

   | Gemini priority | Category |
   |---|---|
   | `high` + `is_security` | `critical` |
   | `high` | `important` |
   | `medium` + `is_security` | `important` |
   | `medium` | `suggestion` |
   | `low` | `suggestion` |

   Unknown priority values must not be silently dropped. Categorize them as `suggestion` and add a non-canonical follow-up note naming the unknown priority so it can be triaged later.
7. Format each new Gemini issue. The outer markdown example uses **four backticks** so the inner `suggestion` fence (three backticks) is not consumed as the closing delimiter:

   ````markdown
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
   ````

   Preserve Gemini's suggestion block when present. Keep content concise enough that the final PR comment stays below GitHub limits.
8. Insert new Gemini issues into the canonical severity sections:
   - `### 🔴 Critical Issues`
   - `### 🟡 Important Issues`
   - `### 💡 Suggestions`
9. Renumber affected issue sections and update summary counts. Preserve existing issue statuses.
10. Upgrade metadata to schema `1.1`:

    ```bash
    METADATA_JSON=$(printf '%s\n' "$EXISTING_CONTENT" \
      | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh" \
          --stdin --last-writer gemini-review-integrator)
    ```

11. Dual-write Gemini metadata during the compatibility window:
    - Add newly consumed integer IDs to `review_sources.gemini.consumed_comment_ids`.
    - Add the same IDs to legacy `gemini_integrated_ids`.
    - Set both `review_sources.gemini.last_integrated_at` and legacy `gemini_integration_date` to the current UTC timestamp.
    - Set `last_writer` / `skill` as appropriate for `gemini-review-integrator`.
    - Preserve `review_sources.codex`, `review_sources.claude`, `[Codex]` issues, and untagged Claude issues.
    - Keep `review_round` unchanged. Gemini integration is not a review producer.
12. Replace the hidden metadata block with `review-metadata-replace.sh`. The script requires a metadata JSON file path; pipe the comment over stdin:

    ```bash
    METADATA_FILE=$(mktemp)
    trap 'rm -f "$METADATA_FILE"' EXIT
    printf '%s' "$METADATA_JSON" > "$METADATA_FILE"

    UPDATED_CONTENT=$(printf '%s\n' "$EXISTING_CONTENT" \
      | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-replace.sh" \
          --stdin --metadata-file "$METADATA_FILE")
    ```

13. Write through `cache-write-comment.sh --stdin "$PR_NUMBER" --expected-content-hash "$EXPECTED_CONTENT_HASH"`:

    ```bash
    printf '%s\n' "$UPDATED_CONTENT" \
      | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh" \
          --stdin "$PR_NUMBER" --expected-content-hash "$EXPECTED_CONTENT_HASH"
    ```

14. Handle `cache-write-comment.sh` exit codes (see `cache-write-comment.sh:22-25`):
    - `0`: success.
    - `1`: covers two distinct failure modes — disambiguate via the shared helper:

      ```bash
      "${PR_REVIEW_TOOLKIT_ROOT}/scripts/disambiguate-stale-source.sh" "$PR_NUMBER"
      # always exits 1
      ```

      Unit-tested in `tests/disambiguate-stale-source-test.sh`.

    - `2`: local error; abort.
    - `3`: remote is newer; re-fetch with `${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-sync.sh "$PR_NUMBER"` (it does a force-refresh internally), then redo Steps 2-13 against the fresh content.
    - `4`: CAS hash mismatch. Re-run Step 2 (`cache-read-comment.sh`) to refresh `$EXISTING_CONTENT`, re-run Step 3 to recapture and re-validate `EXPECTED_CONTENT_HASH`, re-merge only the new Gemini integrations into the newer content, and retry once. If the retry also exits `4`, report `CAS conflict: another writer holds the lock` with the current content hash and stop.

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
