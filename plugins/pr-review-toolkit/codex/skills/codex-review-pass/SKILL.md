---
name: codex-review-pass
description: Use when asked to run a Codex PR review pass, especially a parallel six-agent review. This skill orchestrates read-only subagents for comments, tests, error handling, type design, general code quality, and simplification, then returns one deduplicated review bundle for pr-review-and-document to publish.
---

# Codex Review Pass

Run a Codex PR review pass by launching six read-only subagents, collecting their findings, and returning one normalized review bundle.

## Contract

This skill is the review producer only. It must not write `.pr-review-cache`, create or update PR comments, commit, push, or call `cache-write-comment.sh`. The `pr-review-and-document` Codex skill owns cache/comment reads, writes, metadata updates, CAS retry, and GitHub publication.

Use the current repository diff, PR diff, and existing review content supplied by the caller as context. If the caller did not supply enough context, gather read-only context with `git diff`, `git status`, and helper reads only.

Find the toolkit root in this order:

1. Use `PR_REVIEW_TOOLKIT_ROOT` when set. This is the supported path.
2. If `PR_REVIEW_TOOLKIT_ROOT` is unset, derive the packaged plugin root from the skill path. This SKILL.md lives at `<root>/codex/skills/<skill-name>/SKILL.md`, so `<root>` is exactly three levels up. Ensure `SKILL_PATH` is set in the environment to the absolute path of this SKILL.md before running the snippet (the Codex runtime usually exports this; if not, ask the dev agent to set it):

   ```bash
   : "${SKILL_PATH:?SKILL_PATH must be set to the absolute path of this SKILL.md}"
   PR_REVIEW_TOOLKIT_ROOT="$(cd "$(dirname "$SKILL_PATH")/../../.." && pwd)"
   ```

   Then verify both `<root>/.codex-plugin/plugin.json` and `<root>/scripts/cache-write-comment.sh` exist (sentinels for "we landed at a packaged plugin root, not an arbitrary ancestor"; the first is the Codex plugin manifest that the marketplace resolver requires at a packaged plugin root, the second is the most-referenced helper — if either is renamed in the future, update this list). If either is missing, treat the derivation as failed and proceed to step 3.
3. Stop and ask the dev agent for `PR_REVIEW_TOOLKIT_ROOT`.

After resolving the root via step 1 or 2, canonicalize it to an absolute path so that any subsequent `cd` in the calling workflow (or in scripts that consume `$PR_REVIEW_TOOLKIT_ROOT` and `cd` afterwards) cannot invalidate it:

```bash
PR_REVIEW_TOOLKIT_ROOT="$(cd "$PR_REVIEW_TOOLKIT_ROOT" && pwd)"
```

The review pass may use only these helper scripts, and only for read-only context:

```bash
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/get-pr-number.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh"
```

Before running the workflow, verify the read-only helper scripts are available:

```bash
: "${PR_REVIEW_TOOLKIT_ROOT:?Set PR_REVIEW_TOOLKIT_ROOT to the pr-review-toolkit plugin root}"

for helper in \
  get-pr-number.sh \
  cache-read-comment.sh; do
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

## Workflow

1. Determine PR context. Prefer caller-provided PR number, base branch, head SHA, existing review content, and changed files. If missing, use `get-pr-number.sh`, `cache-read-comment.sh`, `git status`, and `git diff` read-only commands.
2. Build one shared review packet for subagents containing changed files, relevant diff, existing unresolved findings, repository instructions, and any user-requested aspects.
3. Read all six reference prompts from `references/agents/`:
   - `code-reviewer.md`
   - `code-simplifier.md`
   - `silent-failure-hunter.md`
   - `type-design-analyzer.md`
   - `pr-test-analyzer.md`
   - `comment-analyzer.md`
4. Spawn six read-only `explorer` subagents in parallel, one per reference prompt. Each subagent task is the reference prompt plus the shared review packet.
5. Each subagent must return findings only. Subagents must not edit files, write cache files, post comments, run `gh api`, or update metadata.
6. Wait for all six subagents. If one fails, include a non-canonical follow-up note naming the failed aspect; do not silently omit it.
7. Aggregate results:
   - Drop duplicates already present in the existing review comment.
   - Merge duplicates between subagents into one finding with all relevant sources listed.
   - Keep only actionable findings with concrete file references and fixes.
   - Classify each finding as `critical`, `important`, or `suggestion`.
   - Generate stable finding IDs.
8. Return the normalized review bundle described below. Do not publish it.

## Reference Prompts

The reference files hold the full expert instructions for each subagent. Keep the orchestrator here small; update the reference files when an individual review specialty needs deeper rules.

```text
references/agents/code-reviewer.md
references/agents/code-simplifier.md
references/agents/silent-failure-hunter.md
references/agents/type-design-analyzer.md
references/agents/pr-test-analyzer.md
references/agents/comment-analyzer.md
```

## Finding Format

Return findings in this normalized shape:

```text
id: codex:<file>:<symbol-or-nearest-heading>:<diagnostic-kind>:<snippet-hash>
severity: critical | important | suggestion
sources: code-reviewer[, pr-test-analyzer, ...]
title: short issue title
file: path/to/file.ts:42
problem: concise explanation
fix: concrete recommended change
```

Finding IDs are best-effort and should not rely only on line numbers.

## Output Contract

End with:

```text
Codex review bundle:
- PR number: ...
- Head SHA: ...
- Agents completed: code-reviewer, code-simplifier, silent-failure-hunter, type-design-analyzer, pr-test-analyzer, comment-analyzer
- New findings:
  - [critical|important|suggestion] id | title | file:line | sources
- Strengths:
  - ...
- Type ratings:
  - TypeName: ...
- Follow-up notes:
  - ...
```

`pr-review-and-document` is responsible for converting this bundle into canonical markdown sections and writing it to the PR.
