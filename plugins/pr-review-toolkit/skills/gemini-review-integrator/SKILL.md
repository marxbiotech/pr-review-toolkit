---
name: gemini-review-integrator
description: This skill should be used when the user asks to "integrate Gemini review", "merge Gemini suggestions", "add Gemini comments to PR review", "sync Gemini code assist", "combine Gemini feedback", or mentions integrating gemini-code-assist suggestions into the PR review comment. Fetches Gemini Code Assist review comments and integrates non-duplicate, non-outdated suggestions into the pr-review-and-document PR comment.
---

# Gemini Review Integrator

Integrate Gemini Code Assist review suggestions into the canonical `pr-review-and-document` PR comment.

## Contract

Find the toolkit root in this order:

1. Use `AGY_PLUGIN_ROOT` when set by the Antigravity plugin runtime.
2. Use `GROK_PLUGIN_ROOT` when set by the Grok plugin runtime.
3. Use `PR_REVIEW_TOOLKIT_ROOT` when set in the environment.
4. If none is set, derive the packaged plugin root from the skill path. This `SKILL.md` lives at `<root>/skills/<skill-name>/SKILL.md`, so `<root>` is two levels up. Ensure `SKILL_PATH` is set to the absolute path of this `SKILL.md` before running the snippet:

   ```bash
   if [ -n "${AGY_PLUGIN_ROOT:-}" ]; then
     PR_REVIEW_TOOLKIT_ROOT="$AGY_PLUGIN_ROOT"
   elif [ -n "${GROK_PLUGIN_ROOT:-}" ]; then
     PR_REVIEW_TOOLKIT_ROOT="$GROK_PLUGIN_ROOT"
   elif [ -z "${PR_REVIEW_TOOLKIT_ROOT:-}" ]; then
     : "${SKILL_PATH:?SKILL_PATH must be set to the absolute path of this SKILL.md}"
     PR_REVIEW_TOOLKIT_ROOT="$(cd "$(dirname "$SKILL_PATH")/../.." && pwd)"
   fi
   PR_REVIEW_TOOLKIT_ROOT="$(cd "$PR_REVIEW_TOOLKIT_ROOT" && pwd)"
   ```

   Verify `<root>/scripts/cache-write-comment.sh` exists and at least one of `<root>/.antigravity-plugin/plugin.json` or `<root>/.grok-plugin/plugin.json` exists. If missing, stop and ask the dev agent for `PR_REVIEW_TOOLKIT_ROOT`.

Use only these helper scripts:

```bash
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/get-pr-number.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/find-review-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/fetch-gemini-comments.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/extract-content-hash.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-replace.sh"
```

## Workflow

### Step 1: Get PR Number and Verify Prerequisites (Cache-Aware)

```bash
PR_NUMBER=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/get-pr-number.sh")
```

If no PR exists, inform the user and stop.

Verify a `pr-review-and-document` comment exists:

```bash
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/find-review-comment.sh" "$PR_NUMBER"
```

If no review comment exists, inform the user to run `pr-review-and-document` first.

### Step 2: Fetch Gemini Code Assist Comments

```bash
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/fetch-gemini-comments.sh" "$PR_NUMBER"
```

The script returns JSON with Gemini suggestions:
- `id`: Comment ID for deduplication
- `priority`: `high`, `medium`, or `low`
- `is_security`: Whether it's a security issue
- `is_outdated`: Whether the comment is outdated (code changed)
- `file`: File path
- `line`: Line number (`null` if file-level)
- `body`: Full comment body
- `suggestion`: Extracted code suggestion (if any)

### Step 3: Filter and Deduplicate

1. **Exclude outdated comments**: Skip comments where `is_outdated: true`.
2. **Check existing integration**: Parse metadata for `review_sources.gemini.consumed_comment_ids`; fall back to legacy `gemini_integrated_ids`.
3. **Skip already integrated**: Exclude comments whose IDs are already consumed.

### Step 4: Categorize Suggestions

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

### Step 6: Update PR Review Comment

1. Fetch existing comment body and CAS hash:
   ```bash
   EXISTING_CONTENT=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh" "$PR_NUMBER")
   EXPECTED_CONTENT_HASH=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/extract-content-hash.sh" "$PR_NUMBER")
   ```
2. Upgrade metadata to schema `1.1`:
   ```bash
   METADATA_JSON=$(printf '%s\n' "$EXISTING_CONTENT" \
     | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh" \
         --stdin --last-writer gemini-review-integrator)
   ```
3. Dual-write new Gemini IDs and timestamp into both `review_sources.gemini` and legacy top-level fields:
   ```bash
   METADATA_JSON=$(printf '%s' "$METADATA_JSON" | jq \
     --argjson new_ids "$NEW_INTEGRATED_IDS" \
     --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
       .review_sources.gemini.consumed_comment_ids = ((.review_sources.gemini.consumed_comment_ids // []) + $new_ids | unique)
     | .review_sources.gemini.last_integrated_at = $now
     | .gemini_integrated_ids = ((.gemini_integrated_ids // []) + $new_ids | unique)
     | .gemini_integration_date = $now
   ')
   ```
4. Preserve `review_sources.claude`, `review_sources.codex`, `review_sources.grok`, `review_sources.agy`, `[Codex]` issues, `[Grok]` issues, `[AGY]` issues, and untagged Claude issues. Update `Reviewer Sources:` in fixed order `Claude, Gemini, Codex, Grok, AGY` to include `Gemini`.
5. Replace the metadata block and write through `cache-write-comment.sh`:
   ```bash
   METADATA_FILE=$(mktemp)
   trap 'rm -f "$METADATA_FILE"' EXIT
   printf '%s' "$METADATA_JSON" > "$METADATA_FILE"

   UPDATED_CONTENT=$(printf '%s\n' "$EXISTING_CONTENT" \
     | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-replace.sh" \
         --stdin --metadata-file "$METADATA_FILE")

   printf '%s\n' "$UPDATED_CONTENT" \
     | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh" \
         --stdin "$PR_NUMBER" --expected-content-hash "$EXPECTED_CONTENT_HASH"
   ```

### Step 7: Report Integration Results

Summarize total found, outdated (skipped), already integrated (skipped), and newly integrated counts by severity.
