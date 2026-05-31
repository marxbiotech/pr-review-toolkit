---
name: codex-fix-worker
description: Use only when pr-review-resolver asks Codex to fix one selected PR review issue with bounded owned files. This resolver-managed worker edits code and reports validation results, but never updates PR review comments or .pr-review-cache state.
---

# Codex Fix Worker

Fix exactly one selected PR review issue for `pr-review-resolver`.

## Contract

This worker is always resolver-managed. It must edit only the owned files provided by `pr-review-resolver`, run targeted validation, and report results back to the resolver.

Do not read or write `.pr-review-cache`, update PR review comments, create PR comments, call `cache-read-comment.sh`, call `cache-write-comment.sh`, call `gh api`, commit, push, or merge. `pr-review-resolver` owns all review status updates, metadata changes, CAS handling, and comment publication.

Find the toolkit root in this order:

1. Use `PR_REVIEW_TOOLKIT_ROOT` when set. This is the supported path.
2. If `PR_REVIEW_TOOLKIT_ROOT` is unset, derive the packaged plugin root from the skill path. This SKILL.md lives at `<root>/codex/skills/<skill-name>/SKILL.md`, so `<root>` is exactly three levels up. Ensure `SKILL_PATH` is set in the environment to the absolute path of this SKILL.md before running the snippet:

   ```bash
   : "${SKILL_PATH:?SKILL_PATH must be set to the absolute path of this SKILL.md}"
   PR_REVIEW_TOOLKIT_ROOT="$(cd "$(dirname "$SKILL_PATH")/../../.." && pwd)"
   ```

   Verify `<root>/.codex-plugin/plugin.json` exists. If it is missing, treat derivation as failed and proceed to step 3.
3. Stop and ask the dev agent for `PR_REVIEW_TOOLKIT_ROOT`.

Canonicalize the root if it is needed for package-relative context:

```bash
PR_REVIEW_TOOLKIT_ROOT="$(cd "$PR_REVIEW_TOOLKIT_ROOT" && pwd)"
```

This worker does not use review-state scripts. `PR_REVIEW_TOOLKIT_ROOT` exists only to make packaged plugin context explicit.

Resolver-managed state flow:

```text
pr-review-resolver asks the user for a decision
→ pr-review-resolver calls codex-fix-worker with owned files
→ codex-fix-worker edits code and validates
→ codex-fix-worker reports result
→ pr-review-resolver updates review comment/cache
```

## Required Input

`pr-review-resolver` must provide:

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
Resolver context:
This issue was selected by the user in pr-review-resolver.
```

If owned files or the user decision are missing, stop and ask the resolver for them. Do not decide Deferred, N/A, Duplicate, or Skip yourself.

## Workflow

1. Confirm the target issue, user-selected fix approach, and owned files are present.
2. Inspect the referenced code and directly related context.
3. Edit only the owned files. If another file must change, stop and report the required expansion to `pr-review-resolver`.
4. Run targeted validation such as tests, lint, `git diff --check`, script syntax checks, or framework-specific checks relevant to the changed files.
5. Report files changed, validation results, fix summary, and remaining risk to `pr-review-resolver`.

Do not update metadata. Do not mark the review issue as fixed. Do not write the canonical review comment. The resolver will update status after it reviews this worker's result.

## Output Contract

End with:

```text
Files changed:
- path/to/file.ts

Validation:
- command and result

Fix summary:
- ...

Review comment update:
- None. pr-review-resolver must update the canonical review comment.

Commit message draft:
fix(scope): address issue title

Remaining risk:
- ...
```

The resolver, dev agent, or human is responsible for committing and pushing. Do not start another review pass before the code changes are committed or intentionally left uncommitted by the dev agent.
