---
name: pr-cache-sync
description: >
  Sync local PR review cache with GitHub. Use when user says "sync PR cache",
  "pull latest review", "refresh cache", "update local cache", or wants to
  ensure they have the latest review content from GitHub.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)
---

# PR Cache Sync

Synchronize local cache with the latest PR review comment from GitHub.

## When to Use

Invoke this skill when:
- User wants to ensure their local cache is up-to-date
- User suspects the cache might be stale
- User says "sync PR cache", "pull latest review", "refresh cache", or "update local cache"

## Workflow

### Step 1: Get PR Number (Cache-Aware)

```bash
PR_NUMBER=$("${CLAUDE_PLUGIN_ROOT}/scripts/get-pr-number.sh")
```

This uses the branch-to-PR-number cache (`branch-map.json`) with 1-hour TTL, falling back to GitHub API on cache miss.

If no PR exists for the current branch, inform the user and stop.

### Step 2: Run Sync Script

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/cache-sync.sh "$PR_NUMBER"
```

The script will:
1. Show previous cache timestamp (if exists)
2. Force refresh from GitHub
3. Compare hashes to detect changes
4. Report results

### Step 3: Report Results

Inform the user:
- Whether the cache was updated
- If content changed since last cache
- The new cache timestamp

## Example Output

```
=== PR Review Cache Sync ===
PR #123

Previous cache: 2026-02-05T10:30:00Z
Previous hash: sha256:abc123...

Fetching from GitHub...

New cache: 2026-02-05T14:45:00Z
New hash: sha256:def456...

⚠️  Content changed since last cache!

=== Sync complete ===
```

## See Also

完整工作流程說明請參閱 [pr-review-workflow.md](../../docs/pr-review-workflow.md)。
