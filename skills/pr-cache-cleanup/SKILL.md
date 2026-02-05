---
name: pr-cache-cleanup
description: >
  Clean up local PR review cache files for merged or closed PRs. Use when user
  says "clean up cache", "cleanup merged PR caches", "remove old caches",
  "clear review cache", or wants to free up space from stale cache files.
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)
---

# PR Cache Cleanup

Remove cache files for PRs that have been merged or closed.

## When to Use

Invoke this skill when:
- User wants to clean up stale cache files
- User says "clean up cache", "cleanup merged PR caches", "remove old caches", or "clear review cache"
- User wants to free up space from old cache files

**Note:** This skill has `disable-model-invocation: true` because it deletes files and should only be user-triggered.

## Workflow

### Step 1: Preview (Dry Run)

Always start with a dry run to show what would be deleted:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/cache-cleanup.sh --dry-run
```

### Step 2: Confirm with User

Present the preview results to the user:
- How many files would be deleted
- Which PRs they belong to
- PR states (MERGED, CLOSED, NOT_FOUND)

Ask for confirmation before proceeding.

### Step 3: Execute Cleanup

Only after user confirmation:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/cache-cleanup.sh
```

### Step 4: Report Results

Inform the user:
- Number of files deleted
- Number of files kept (open PRs)
- Any errors encountered

## Options

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview only, don't delete |
| `--all` | Remove ALL cache files including open PRs (use with caution) |

## Example Output

```
=== PR Review Cache Cleanup ===

DRY RUN - no files will be deleted

Scanning cache files...

Would delete: .pr-review-cache/pr-123.json (PR #123, state: MERGED, cached: 2026-02-01T10:00:00Z)
Would delete: .pr-review-cache/pr-124.json (PR #124, state: CLOSED, cached: 2026-02-02T10:00:00Z)
Keeping: .pr-review-cache/pr-125.json (PR #125 is still open)

=== Summary ===
Would delete: 2 files
Kept: 1 files
```

## See Also

完整工作流程說明請參閱 [pr-review-workflow.md](../../docs/pr-review-workflow.md)。
