---
name: pr-review-and-document
description: Use when asked to review a PR with Codex and save, document, post, or update the review results. This skill owns PR comment/cache state, invokes codex-review-pass for the six-subagent review bundle, and publishes one canonical review comment through .pr-review-cache/pr-#.json.
---

# PR Review and Document

Run a Codex PR review and publish the results to the canonical pr-review-toolkit PR comment.

## Contract

This skill owns all review state writes. Use `.pr-review-cache/pr-#.json` as the only PR review state file. Do not create extra Codex cache files, extra PR comments, commits, pushes, or direct `gh api` comment updates.

`codex-review-pass` owns review analysis only. It launches the six read-only subagents and returns a normalized review bundle. This skill converts that bundle into canonical markdown, updates metadata, and writes through `cache-write-comment.sh`. If the `codex-review-pass` skill body is not already loaded, read the sibling `../codex-review-pass/SKILL.md` before invoking Step 4 so the six-agent review contract and subagent prompts are available.

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
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-replace.sh"
```

Before running the workflow, verify helper scripts are executable and `scripts/lib/common.sh` is readable.

## Workflow

1. Get the PR number with `get-pr-number.sh`.
2. Read the existing canonical review comment:

   ```bash
   set +e
   EXISTING_CONTENT=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh" "$PR_NUMBER")
   rc=$?
   set -e

   case $rc in
     0) MODE=append ;;
     2) MODE=bootstrap ;;
     *) echo "cache-read-comment.sh failed with exit $rc" >&2; exit "$rc" ;;
   esac
   ```

3. In append mode, read `.pr-review-cache/pr-${PR_NUMBER}.json` and save `.content_hash` as `EXPECTED_CONTENT_HASH`.
4. Run `codex-review-pass` and provide the PR number, current diff context, changed files, existing review content, and any user-requested scope. The pass must run all six subagents: `code-reviewer`, `code-simplifier`, `silent-failure-hunter`, `type-design-analyzer`, `pr-test-analyzer`, and `comment-analyzer`.
5. Convert the returned review bundle into canonical review sections:
   - `### 🔴 Critical Issues`
   - `### 🟡 Important Issues`
   - `### 💡 Suggestions`
   - `### ✨ Strengths`
   - `### 📋 Type Design Ratings`
   - `### 🎯 Action Plan`
6. Append only new Codex findings. Preserve existing `[Gemini]`, `[Codex]`, and untagged Claude issues. Treat untagged issues as Claude issues.
7. Upgrade metadata to schema `1.1` with `review-metadata-upgrade.sh --last-writer pr-review-and-document`.
8. Update metadata:
   - `last_writer`: `pr-review-and-document`
   - `skill`: `pr-review-and-document`
   - `review_sources.codex.last_reviewed_head`: current HEAD SHA
   - `review_sources.codex.last_reviewed_at`: UTC timestamp
   - `review_sources.codex.posted_finding_ids`: stable IDs from the review bundle
   - `review_sources.codex.agents_run`: the six Codex review agents
   - `review_sources.claude.agents_run`: preserve existing value, or `[]` on Codex bootstrap
   - top-level `agents_run`: preserve as the Claude compatibility mirror, or `[]` on Codex bootstrap
9. Increment PR-global `review_round` only when this run adds new findings. Empty refreshes update Codex source timestamps without changing counts or existing statuses.
10. Replace the hidden metadata block using `review-metadata-replace.sh`.
11. Write the comment through `cache-write-comment.sh --stdin "$PR_NUMBER"` with `--expected-content-hash "$EXPECTED_CONTENT_HASH"` when present.
12. If `cache-write-comment.sh` exits `4`, re-read, merge your changes into the newer content, and retry once. If the retry also exits `4`, stop and report `CAS conflict: another writer holds the lock` with the current content hash.

## Bootstrap Mode

When no canonical comment exists, create a new comment with the standard `<!-- pr-review-metadata` marker, summary table, canonical issue sections, strengths, type ratings, and action plan. Bootstrap must not run concurrently with another producer. If duplicate canonical comments are detected, stop and ask the dev agent to keep only the `.pr-review-cache/pr-#.json` `source_comment_id` comment.

## Canonical Finding Format

Use this details format for Codex findings:

```markdown
<details>
<summary><b>N. ⚠️ [Codex] Issue title</b></summary>

**Source:** Codex
**Agents:** code-reviewer, pr-test-analyzer
**File:** `path/to/file.ts:42`
**Finding ID:** `codex:path:symbol:kind:hash`

**Problem:** ...

**Fix:** ...

</details>
```

Actionable findings must live in the canonical severity sections and be counted in the summary table. Use a `### 🟠 Codex Follow-up Notes` section only for non-canonical notes such as a failed subagent, validation observations, or duplicate-risk notes.

## Output Contract

End with:

```text
PR review comment:
- PR: #123
- Mode: bootstrap | append
- New Codex findings: N
- Agents run: code-reviewer, code-simplifier, silent-failure-hunter, type-design-analyzer, pr-test-analyzer, comment-analyzer
- Comment URL: ...

Review state:
- Cache: .pr-review-cache/pr-123.json
- Metadata schema: 1.1
- Review round: N
```
