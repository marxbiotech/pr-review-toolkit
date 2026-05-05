---
name: codex-fix-worker
description: Use when asked to have Codex fix one selected PR review issue from the pr-review-toolkit canonical review comment, with bounded owned files and .pr-review-cache/pr-#.json as the only review state contract.
---

# Codex Fix Worker

Fix exactly one selected PR review issue and update that issue's status in the canonical pr-review-toolkit review comment.

## Contract

Use `.pr-review-cache/pr-#.json` as the only PR review state file. Do not create extra cache files or PR comments. Do not commit, push, merge, or directly call `gh api` to update comments.

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

## Required Input

The dev agent must provide:

```text
PR number: 123
Issue source: Claude / Gemini / Codex
Issue title: ...
Issue file references:
- path/to/file.ts:42
Decision:
Fix using approach X.
Owned files:
- path/to/file.ts
```

If owned files or the user decision are missing, stop and ask for them. Do not decide Deferred or N/A yourself.

## Workflow

1. Read `.pr-review-cache/pr-${PR_NUMBER}.json` and save `.content_hash` as `EXPECTED_CONTENT_HASH`.
2. Read the current review content with `cache-read-comment.sh "$PR_NUMBER"`.
3. Confirm the target issue is still unresolved (`⚠️` or `🔴`). If it is already `✅` or `⏭️`, stop and report that no fix is needed.
4. Upgrade metadata to schema `1.1` if needed:
   ```bash
   METADATA_JSON=$(printf '%s\n' "$REVIEW_CONTENT" | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh" --stdin --last-writer codex-fix-worker)
   ```
   After editing metadata JSON, use `review-metadata-replace.sh --stdin --metadata-file "$METADATA_FILE"` to write it back without touching unrelated issue sections.
5. Edit only the owned files. If another file must change, stop and report the required expansion to the dev agent.
6. Run targeted validation such as tests, lint, `git diff --check`, or script syntax checks relevant to the changed files.
7. Re-read the cache hash before writing. If it differs from `EXPECTED_CONTENT_HASH`, re-read the latest comment, merge only this issue's status update, and retry once.
8. Mark only the target issue as `✅`, add a concise fix summary and validation result, update summary counts, `updated_at`, and `last_writer`.
9. Keep existing `review_round` unchanged.
10. Write through `cache-write-comment.sh --stdin "$PR_NUMBER" --expected-content-hash "$EXPECTED_CONTENT_HASH"`.
11. If the script exits `4`, re-read, merge, and retry once. If it still fails, report the conflict.

## Metadata Rules

- `last_writer`: `codex-fix-worker`
- `review_round`: unchanged
- `review_sources`: preserve all sources
- top-level `agents_run`: preserve during the Phase 2 compatibility window when present

Do not rewrite the whole comment structure. Make the smallest status update needed for the selected issue.

## Output Contract

End with:

```text
Files changed:
- path/to/file.ts

Validation:
- command and result

Review comment update:
- Marked "Issue title" as fixed.

Commit message draft:
fix(scope): address issue title

Remaining risk:
- ...
```

The dev agent or human is responsible for committing and pushing. Do not start another review pass before the code changes are committed or intentionally left uncommitted by the dev agent.
