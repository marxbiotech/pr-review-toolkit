---
name: pr-review-and-document
description: Use when asked to review a PR with Antigravity (AGY) or Grok and save, document, post, or update the review results. This skill owns PR comment/cache state, invokes agy-review-pass (in Antigravity) or grok-review-pass (in Grok) for the six-subagent review bundle, and publishes one canonical review comment through .pr-review-cache/pr-#.json.
---

# PR Review and Document

Run an Antigravity (`agy`) or Grok PR review and publish the results to the canonical `pr-review-toolkit` PR comment.

## Contract

This skill owns all review state writes. Use `.pr-review-cache/pr-#.json` as the only PR review state file. Do not create extra cache files, extra PR comments, commits, pushes, or direct `gh api` comment updates.

Determine the active runtime producer:
- **In Antigravity (`agy`)**: `agy-review-pass` owns review analysis. Read `${PR_REVIEW_TOOLKIT_ROOT}/skills/agy-review-pass/SKILL.md` before invoking Step 4 if not already loaded. Findings use `[AGY]` title prefix, `**Source:** AGY`, `agy:...` finding IDs, `review_sources.agy`, and `### 🟠 AGY Follow-up Notes`.
- **In Grok**: `grok-review-pass` owns review analysis. Read `${PR_REVIEW_TOOLKIT_ROOT}/skills/grok-review-pass/SKILL.md` before invoking Step 4 if not already loaded. Findings use `[Grok]` title prefix, `**Source:** Grok`, `grok:...` finding IDs, `review_sources.grok`, and `### 🟠 Grok Follow-up Notes`.

Find the toolkit root in this order:

1. Use `AGY_PLUGIN_ROOT` when set by the Antigravity plugin runtime.
2. Use `GROK_PLUGIN_ROOT` when set by the Grok plugin runtime.
3. Use `PR_REVIEW_TOOLKIT_ROOT` when set in the environment.
4. If none is set, derive the packaged plugin root from the skill path. This `SKILL.md` lives at `<root>/skills/<skill-name>/SKILL.md`, so `<root>` is two levels up. Ensure `SKILL_PATH` is set in the environment to the absolute path of this `SKILL.md` before running the snippet:

   ```bash
   if [ -n "${AGY_PLUGIN_ROOT:-}" ]; then
     PR_REVIEW_TOOLKIT_ROOT="$AGY_PLUGIN_ROOT"
   elif [ -n "${GROK_PLUGIN_ROOT:-}" ]; then
     PR_REVIEW_TOOLKIT_ROOT="$GROK_PLUGIN_ROOT"
   elif [ -z "${PR_REVIEW_TOOLKIT_ROOT:-}" ]; then
     : "${SKILL_PATH:?SKILL_PATH must be set to the absolute path of this SKILL.md}"
     PR_REVIEW_TOOLKIT_ROOT="$(cd "$(dirname "$SKILL_PATH")/../.." && pwd)"
   fi
   ```

   Verify `<root>/scripts/cache-write-comment.sh` exists and at least one of `<root>/.antigravity-plugin/plugin.json` or `<root>/.grok-plugin/plugin.json` exists. If missing, treat derivation as failed and proceed to step 5.
5. Stop and ask the dev agent for `PR_REVIEW_TOOLKIT_ROOT`.

Canonicalize the root before using helper scripts:

```bash
PR_REVIEW_TOOLKIT_ROOT="$(cd "$PR_REVIEW_TOOLKIT_ROOT" && pwd)"
```

Use only these scripts for review state:

```bash
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/get-pr-number.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-sync.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/extract-content-hash.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/disambiguate-stale-source.sh"
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

3. In append mode, extract the cache `content_hash` for CAS via the shared helper:

   ```bash
   set -euo pipefail
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

   The helper centralizes the contract documented in `cache-write-comment.sh:36-44` and is unit-tested in `tests/extract-content-hash-test.sh`. See [`scripts/extract-content-hash.sh`](../../../../scripts/extract-content-hash.sh) for the implementation.
4. Run `agy-review-pass` (in Antigravity) or `grok-review-pass` (in Grok) and provide the PR number, current diff context, changed files, existing review content, and any user-requested scope. The pass must return a bundle whose `Agents completed:` line names exactly these six agents: `code-reviewer`, `code-simplifier`, `silent-failure-hunter`, `type-design-analyzer`, `pr-test-analyzer`, `comment-analyzer`. Verify with:

   ```bash
   set -euo pipefail

   EXPECTED_AGENTS=$(printf '%s\n' \
     code-reviewer code-simplifier silent-failure-hunter \
     type-design-analyzer pr-test-analyzer comment-analyzer | sort -u)

   if [ -z "$BUNDLE" ]; then
     echo "error: review-pass produced no bundle" >&2
     exit 2
   fi

   AGENTS_LINE=$(printf '%s\n' "$BUNDLE" | tr -d '\r' | awk '
     /^- *Agents completed:/ { collecting=1; sub(/^- *Agents completed: */, ""); buf=$0; next }
     collecting && /^[[:space:]]+/ { sub(/^[[:space:]]+/, " "); buf = buf $0; next }
     collecting { print buf; printed=1; exit }
     END { if (collecting && !printed) print buf }
   ')

   if [ -z "$AGENTS_LINE" ]; then
     echo "error: review-pass bundle does not contain an 'Agents completed:' line" >&2
     exit 2
   fi

   ACTUAL_AGENTS=$(printf '%s\n' "$AGENTS_LINE" \
     | tr ',' '\n' \
     | awk '{$1=$1; if (length($0)) print}' \
     | sort -u)

   MISSING=$(comm -23 <(printf '%s\n' "$EXPECTED_AGENTS") <(printf '%s\n' "$ACTUAL_AGENTS"))
   if [ -n "$MISSING" ]; then
     echo "error: review-pass returned an incomplete bundle. Missing agents:" >&2
     while IFS= read -r a; do printf '  - %s\n' "$a" >&2; done <<< "$MISSING"
     echo "Do not bootstrap or append from a partial bundle. Surface the bundle's Follow-up notes and abort." >&2
     exit 2
   fi
   ```

   This check applies in both bootstrap and append modes — a partial bundle is never published.
5. Convert the returned review bundle into canonical review sections:
   - `### 🔴 Critical Issues`
   - `### 🟡 Important Issues`
   - `### 💡 Suggestions`
   - `### ✨ Strengths`
   - `### 📋 Type Design Ratings`
   - `### 🎯 Action Plan`

   Below the `## 🤖 PR Review` heading, render a `**Reviewer Sources:**` line in fixed order `Claude, Gemini, Codex, Grok, AGY`. Include a source only if it has participated:
   - `Claude` when `review_sources.claude.last_reviewed_at != null`
   - `Gemini` when `review_sources.gemini.last_integrated_at != null` or `review_sources.gemini.consumed_comment_ids` is non-empty
   - `Codex` when `review_sources.codex.last_reviewed_at != null`
   - `Grok` when `review_sources.grok.last_reviewed_at != null`
   - `AGY` when `review_sources.agy.last_reviewed_at != null`
   (Step 8 sets `review_sources.agy.last_reviewed_at` in Antigravity or `review_sources.grok.last_reviewed_at` in Grok, so after this skill finishes the line will always include the active runtime source.)
6. Append only new findings for the active runtime (`[AGY]` in Antigravity, `[Grok]` in Grok). Preserve existing `[Gemini]`, `[Codex]`, `[Grok]`, `[AGY]`, and untagged Claude issues. Treat untagged issues as Claude issues.
7. Upgrade metadata to schema `1.1`. In append mode pipe the existing comment; in bootstrap mode pipe a minimal seed so the upgrade script can produce a complete 1.1 envelope:

   ```bash
   if [ "$MODE" = "append" ]; then
     UPGRADE_INPUT="$EXISTING_CONTENT"
   else
     UPGRADE_INPUT=$'<!-- pr-review-metadata\n{}\n-->\n'
   fi

   METADATA_JSON=$(printf '%s\n' "$UPGRADE_INPUT" \
     | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh" \
         --stdin --last-writer pr-review-and-document)
   ```

8. Update metadata (use `jq` against `$METADATA_JSON`):
   - `last_writer`: `pr-review-and-document`
   - `skill`: `pr-review-and-document`
   - For Antigravity (`agy`):
     - `review_sources.agy.last_reviewed_head`: current HEAD SHA
     - `review_sources.agy.last_reviewed_at`: UTC timestamp
     - `review_sources.agy.posted_finding_ids`: stable `agy:...` IDs from the review bundle (merged with existing `posted_finding_ids`)
     - `review_sources.agy.agents_run`: the six review agents
     - `review_sources.grok`: preserve existing value
   - For Grok:
     - `review_sources.grok.last_reviewed_head`: current HEAD SHA
     - `review_sources.grok.last_reviewed_at`: UTC timestamp
     - `review_sources.grok.posted_finding_ids`: stable `grok:...` IDs from the review bundle (merged with existing `posted_finding_ids`)
     - `review_sources.grok.agents_run`: the six review agents
     - `review_sources.agy`: preserve existing value
   - `review_sources.claude.agents_run`: preserve existing value, or `[]` on bootstrap
   - `review_sources.codex`: preserve existing value
   - `review_sources.gemini`: preserve existing value
   - top-level `agents_run`: preserve as the Claude compatibility mirror, or `[]` on bootstrap
9. Increment PR-global `review_round` only when this run adds new findings. Empty refreshes update the active runtime source timestamps without changing counts or existing statuses.
10. Replace the hidden metadata block with `review-metadata-replace.sh`. The script requires a metadata JSON file path; pipe the comment over stdin:

    ```bash
    METADATA_FILE=$(mktemp)
    trap 'rm -f "$METADATA_FILE"' EXIT
    printf '%s' "$METADATA_JSON" > "$METADATA_FILE"

    UPDATED_CONTENT=$(printf '%s\n' "$EXISTING_CONTENT" \
      | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-replace.sh" \
          --stdin --metadata-file "$METADATA_FILE")
    ```

    In bootstrap mode there is no `$EXISTING_CONTENT` to replace into; assemble the canonical sections around the metadata block directly.
11. Write the comment through `cache-write-comment.sh --stdin "$PR_NUMBER"` with `--expected-content-hash "$EXPECTED_CONTENT_HASH"` when present:

    ```bash
    if [ -n "${EXPECTED_CONTENT_HASH:-}" ]; then
      printf '%s\n' "$UPDATED_CONTENT" \
        | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh" \
            --stdin "$PR_NUMBER" --expected-content-hash "$EXPECTED_CONTENT_HASH"
    else
      printf '%s\n' "$UPDATED_CONTENT" \
        | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh" \
            --stdin "$PR_NUMBER"
    fi
    ```

12. Handle `cache-write-comment.sh` exit codes (see `cache-write-comment.sh:22-25`):
    - `0`: success.
    - `1`: covers two distinct failure modes — disambiguate via the shared helper:

      ```bash
      set +e
      "${PR_REVIEW_TOOLKIT_ROOT}/scripts/disambiguate-stale-source.sh" "$PR_NUMBER"
      disambig_rc=$?
      set -e

      case $disambig_rc in
        1)
          # Nominal: recovery advice printed to stderr; follow it.
          exit 1
          ;;
        10)
          echo "Cannot disambiguate cache-write-comment.sh exit 1 cause; manual intervention required." >&2
          exit 10
          ;;
        *)
          echo "disambiguate-stale-source.sh exited unexpectedly (rc=$disambig_rc)" >&2
          exit "$disambig_rc"
          ;;
      esac
      ```

      Unit-tested in `tests/disambiguate-stale-source-test.sh`.

    - `2`: local error; abort.
    - `3`: remote is newer. Re-fetch the canonical comment with `${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-sync.sh "$PR_NUMBER"`, then redo Steps 2-11 against the fresh content.
    - `4`: CAS hash mismatch. Re-run Step 2 (`cache-read-comment.sh`) to refresh `$EXISTING_CONTENT`, re-run Step 3 to recapture and re-validate `EXPECTED_CONTENT_HASH`, re-merge new findings into the newer content, and retry once. If the retry also exits `4`, stop and report `CAS conflict: another writer holds the lock` with the current content hash.

## Bootstrap Mode

When no canonical comment exists, create a new comment with the standard `<!-- pr-review-metadata` marker, summary table, canonical issue sections, strengths, type ratings, and action plan. Bootstrap must not run concurrently with another producer. If duplicate canonical comments are detected, stop and ask the dev agent to keep only the `.pr-review-cache/pr-#.json` `source_comment_id` comment.

## Canonical Finding Format

For Antigravity (`agy`) findings:

```markdown
<details>
<summary><b>N. ⚠️ [AGY] Issue title</b></summary>

**Source:** AGY
**Agents:** code-reviewer, pr-test-analyzer
**File:** `path/to/file.ts:42`
**Finding ID:** `agy:path:symbol:kind:hash`

**Problem:** ...

**Fix:** ...

</details>
```

For Grok findings:

```markdown
<details>
<summary><b>N. ⚠️ [Grok] Issue title</b></summary>

**Source:** Grok
**Agents:** code-reviewer, pr-test-analyzer
**File:** `path/to/file.ts:42`
**Finding ID:** `grok:path:symbol:kind:hash`

**Problem:** ...

**Fix:** ...

</details>
```

Actionable findings must live in the canonical severity sections and be counted in the summary table. Use a `### 🟠 AGY Follow-up Notes` (or `### 🟠 Grok Follow-up Notes`) section only for non-canonical notes such as a failed subagent, validation observations, or duplicate-risk notes.

## Output Contract

End with:

```text
PR review comment:
- PR: #123
- Mode: bootstrap | append
- New findings: N
- Agents run: code-reviewer, code-simplifier, silent-failure-hunter, type-design-analyzer, pr-test-analyzer, comment-analyzer
- Comment URL: ...

Review state:
- Cache: .pr-review-cache/pr-123.json
- Metadata schema: 1.1
- Review round: N
```
