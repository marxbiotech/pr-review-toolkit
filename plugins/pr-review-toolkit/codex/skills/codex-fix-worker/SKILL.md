---
name: codex-fix-worker
description: Use when asked to have Codex fix one selected PR review issue from the pr-review-toolkit canonical review comment, with bounded owned files and .pr-review-cache/pr-#.json as the only review state contract.
---

# Codex Fix Worker

Fix exactly one selected PR review issue and update that issue's status in the canonical pr-review-toolkit review comment.

## Contract

Use `.pr-review-cache/pr-#.json` as the only PR review state file. Do not create extra cache files or PR comments. Do not commit, push, merge, or directly call `gh api` to update comments.

Find the toolkit root in this order:

1. Use `PR_REVIEW_TOOLKIT_ROOT` when set. This is the supported path.
2. If `PR_REVIEW_TOOLKIT_ROOT` is unset, derive the packaged plugin root from the skill path. This SKILL.md lives at `<root>/codex/skills/<skill-name>/SKILL.md`, so `<root>` is exactly three levels up. Substitute `$SKILL_PATH` with the absolute path of this SKILL.md (the Codex runtime usually exposes this; if not, ask the dev agent for it before running the snippet):

   ```bash
   : "${SKILL_PATH:?SKILL_PATH must be set to the absolute path of this SKILL.md}"
   PR_REVIEW_TOOLKIT_ROOT="$(cd "$(dirname "$SKILL_PATH")/../../.." && pwd)"
   ```

   Then verify both `<root>/.codex-plugin/plugin.json` and `<root>/scripts/cache-write-comment.sh` exist (sentinels for "we landed at a packaged plugin root, not an arbitrary ancestor"; the first is the Codex marketplace manifest path, the second is the most-referenced helper — if either is renamed in the future, update this list). If either is missing, treat the derivation as failed and proceed to step 3.
3. Stop and ask the dev agent for `PR_REVIEW_TOOLKIT_ROOT`.

After resolving the root via step 1 or 2, canonicalize it to an absolute path so helpers that `cd` before invoking siblings cannot break:

```bash
PR_REVIEW_TOOLKIT_ROOT="$(cd "$PR_REVIEW_TOOLKIT_ROOT" && pwd)"
```

Use only these scripts for review state:

```bash
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/get-pr-number.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-replace.sh"
```

Before running the workflow, verify the helper scripts are available:

```bash
: "${PR_REVIEW_TOOLKIT_ROOT:?Set PR_REVIEW_TOOLKIT_ROOT to the pr-review-toolkit plugin root}"

for helper in \
  get-pr-number.sh \
  cache-read-comment.sh \
  cache-write-comment.sh \
  review-metadata-upgrade.sh \
  review-metadata-replace.sh; do
  if [ ! -x "${PR_REVIEW_TOOLKIT_ROOT}/scripts/${helper}" ]; then
    echo "Missing executable helper: ${PR_REVIEW_TOOLKIT_ROOT}/scripts/${helper}" >&2
    echo "Hint: PR_REVIEW_TOOLKIT_ROOT must point at the packaged plugin root" >&2
    echo "      (e.g. <repo>/plugins/pr-review-toolkit), not the repo root." >&2
    exit 2
  fi
done
if [ ! -r "${PR_REVIEW_TOOLKIT_ROOT}/scripts/lib/common.sh" ]; then
  echo "Missing readable shared library: ${PR_REVIEW_TOOLKIT_ROOT}/scripts/lib/common.sh" >&2
  echo "(The cache and PR-number helpers above source this file; the metadata helpers do not, but it ships in the package and we treat its absence as a packaging failure.)" >&2
  exit 2
fi
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

1. Read the current review content with `cache-read-comment.sh "$PR_NUMBER"`. The cache file MUST exist (fix-worker only operates on PRs that already have a canonical review comment); if `cache-read-comment.sh` exits `2`, abort and ask the dev agent to bootstrap first.
2. Read `.pr-review-cache/pr-${PR_NUMBER}.json` and save `.content_hash` as `EXPECTED_CONTENT_HASH`.
3. Confirm the target issue is still unresolved (`⚠️` or `🔴`). If it is already `✅` or `⏭️`, stop and report that no fix is needed.
4. Upgrade metadata to schema `1.1` if needed:
   ```bash
   METADATA_JSON=$(printf '%s\n' "$REVIEW_CONTENT" | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh" --stdin --last-writer codex-fix-worker)
   ```
   After editing metadata JSON (e.g. via `jq`), write it back without touching unrelated issue sections:
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
5. Edit only the owned files. If another file must change, stop and report the required expansion to the dev agent.
6. Run targeted validation such as tests, lint, `git diff --check`, or script syntax checks relevant to the changed files.
7. Mark only the target issue as `✅`, add a concise fix summary and validation result, update summary counts, `updated_at`, and `last_writer`.
8. Keep existing `review_round` unchanged.
9. Write through `cache-write-comment.sh --stdin "$PR_NUMBER" --expected-content-hash "$EXPECTED_CONTENT_HASH"`.
10. If the script exits `4`, re-read, merge, and retry once. If it still fails, report the conflict.

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
