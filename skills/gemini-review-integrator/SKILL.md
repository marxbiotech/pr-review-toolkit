---
name: gemini-review-integrator
description: This skill should be used when the user asks to "integrate Gemini review", "merge Gemini suggestions", "add Gemini comments to PR review", "sync Gemini code assist", "combine Gemini feedback", or mentions integrating gemini-code-assist suggestions into the PR review comment. Fetches Gemini Code Assist review comments and integrates non-duplicate, non-outdated suggestions into the pr-review-and-document PR comment.
---

# Gemini Review Integrator

Integrate Gemini Code Assist review suggestions into the pr-review-and-document PR comment.

## When to Use

Invoke this skill when:
- A PR has both Gemini Code Assist reviews and a pr-review-and-document comment
- Need to consolidate all review feedback into a single location
- Want to track Gemini suggestions alongside Claude's PR review

## Workflow

### Step 1: Get PR Number and Verify Prerequisites (Cache-Aware)

```bash
PR_NUMBER=$("${CLAUDE_PLUGIN_ROOT}/scripts/get-pr-number.sh")
```

This uses the branch-to-PR-number cache (`branch-map.json`) with 1-hour TTL, falling back to GitHub API on cache miss.

If no PR exists, inform the user and stop.

Verify pr-review-and-document comment exists:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/find-review-comment.sh "$PR_NUMBER"
```

If no review comment exists, inform the user to run `pr-review-and-document` skill first.

### Step 2: Fetch Gemini Code Assist Comments

Fetch all PR review comments (inline code comments):

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/fetch-gemini-comments.sh "$PR_NUMBER"
```

The script returns JSON with Gemini suggestions, including:
- `id`: Comment ID for deduplication
- `priority`: high, medium, or low
- `is_security`: Whether it's a security issue
- `is_outdated`: Whether the comment is outdated (code changed)
- `file`: File path
- `line`: Line number (null if file-level)
- `body`: Full comment body
- `suggestion`: Extracted code suggestion (if any)

### Step 3: Filter and Deduplicate

Apply filters to Gemini suggestions:

1. **Exclude outdated comments**: Skip comments where `is_outdated: true`
2. **Check existing integration**: Parse pr-review-and-document comment metadata for `gemini_integrated_ids`
3. **Skip already integrated**: Exclude comments whose IDs are in `gemini_integrated_ids`

### Step 4: Categorize Suggestions

Map Gemini priorities to pr-review-and-document categories:

| Gemini Priority | PR Review Category |
|-----------------|-------------------|
| `high` + `is_security` | 🔴 Critical Issues |
| `high` | 🟡 Important Issues |
| `medium` + `is_security` | 🟡 Important Issues |
| `medium` | 💡 Suggestions |
| `low` | 💡 Suggestions |

### Step 5: Format Integrated Suggestions

For each new Gemini suggestion, format as:

```markdown
<details>
<summary><b>N. ⚠️ [Gemini] Issue Title</b></summary>

**Source:** Gemini Code Assist
**File:** `path/to/file.ts:line`

**Problem:** Description from Gemini comment.

**Suggested Fix:**
```suggestion
code here
```

</details>
```

Key formatting rules:
- Prefix title with `[Gemini]` to identify source
- Use `⚠️` status indicator (pending review)
- Include `**Source:** Gemini Code Assist` line
- Preserve Gemini's suggestion code block if present

### Step 6: Update PR Review Comment

1. Fetch existing pr-review-and-document comment body
2. Parse metadata JSON from `<!-- pr-review-metadata ... -->` block
3. Update metadata:
   - Add `gemini_integrated_ids` array with newly integrated comment IDs
   - Increment issue counts in `issues` object
   - Update `updated_at` timestamp
4. Insert new Gemini issues into appropriate sections (Critical, Important, Suggestions)
5. Renumber existing issues to accommodate new entries

Pipe updated content to `cache-write-comment.sh` via `--stdin`:

```bash
echo "$UPDATED_CONTENT" | ${CLAUDE_PLUGIN_ROOT}/scripts/cache-write-comment.sh --stdin "$PR_NUMBER"
```

This updates local cache and syncs to GitHub in one step, without temp files.

### Step 7: Report Integration Results

Summarize what was integrated:

```
Gemini Review Integration Complete:
- Found: X Gemini comments
- Outdated (skipped): Y
- Already integrated (skipped): Z
- Newly integrated: W
  - Critical: A
  - Important: B
  - Suggestions: C
```

## Metadata Schema Extension

The pr-review-and-document metadata is extended with:

```json
{
  "gemini_integrated_ids": [2726014213, 2726014217, ...],
  "gemini_integration_date": "2026-01-26T12:00:00Z"
}
```

This enables:
- Tracking which Gemini comments have been integrated
- Preventing duplicate integration across multiple runs
- Audit trail for integrated suggestions

## Gemini Comment Structure

Gemini Code Assist comments have these characteristics:

**Priority Indicators (in body):**
- `![high](...)` - High priority
- `![medium](...)` - Medium priority
- `![security-medium](...)` or `![security-high](...)` - Security-related

**Outdated Detection:**
- GitHub API field `position: null` indicates the code has changed
- These comments should be skipped as they may no longer apply

**Code Suggestions:**
- Enclosed in ````suggestion` blocks
- Should be preserved in integration

## Handling Multiple Gemini Review Rounds

Gemini may perform multiple review rounds on a PR. The integration handles this by:

1. **ID-based deduplication**: Each comment has a unique ID
2. **Cumulative tracking**: `gemini_integrated_ids` grows with each integration
3. **New comments only**: Only comments not in `gemini_integrated_ids` are processed

To re-integrate after Gemini runs another review:
1. Run this skill again
2. Only new comments will be added
3. Previously integrated comments remain unchanged

## Status Indicators for Gemini Issues

| Indicator | Meaning |
|-----------|---------|
| ⚠️ | Pending review (newly integrated from Gemini) |
| ✅ | Fixed / Resolved |
| ⏭️ | Deferred / Not applicable |
| 🔴 | Escalated to blocking |

Initial status for all Gemini integrations is `⚠️` (pending review).

## Example Integration

**Before (pr-review-and-document comment):**
```markdown
### 🟡 Important Issues

<details>
<summary><b>1. ✅ Some Claude-found issue</b></summary>
...
</details>
```

**After integration:**
```markdown
### 🟡 Important Issues

<details>
<summary><b>1. ✅ Some Claude-found issue</b></summary>
...
</details>

<details>
<summary><b>2. ⚠️ [Gemini] Suppress stderr hides errors</b></summary>

**Source:** Gemini Code Assist
**File:** `.claude/skills/pr-review-and-document/scripts/find-review-comment.sh:19`

**Problem:** Suppressing stderr with `2>/dev/null` can hide important underlying errors.

**Suggested Fix:**
```suggestion
  PR_NUMBER=$(gh pr view --json number -q '.number' || echo "")
```

</details>
```

## Validation Checklist

Before completing integration:

- [ ] PR number correctly identified
- [ ] pr-review-and-document comment exists
- [ ] Gemini comments fetched successfully
- [ ] Outdated comments filtered out
- [ ] Previously integrated comments skipped
- [ ] New comments categorized correctly
- [ ] Metadata updated with integrated IDs
- [ ] Issue counts updated accurately
- [ ] Comment posted successfully

## Error Handling

| Error | Action |
|-------|--------|
| No PR found | Inform user, stop |
| No review comment | Suggest running pr-review-and-document first |
| No Gemini comments | Inform user, nothing to integrate |
| API failure | Report error with details |
| All comments outdated | Inform user, nothing to integrate |
| All comments already integrated | Inform user, up to date |
