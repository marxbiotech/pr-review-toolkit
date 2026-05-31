---
name: pr-review-resolver
description: Use when asked to resolve, address, process, or discuss PR review findings with Codex. This skill is an interactive Traditional Chinese resolver that reads the canonical pr-review-toolkit comment, handles unresolved Claude/Gemini/Codex issues one by one with user decisions, coordinates bounded fix work, and updates review status through .pr-review-cache/pr-#.json.
---

# PR Review Resolver

Interactively resolve unresolved PR review findings from the canonical pr-review-toolkit comment.

## Contract

Always communicate with the user in Traditional Chinese (`zh-TW`). Process issues one at a time and wait for the user's decision for each issue. Do not decide Fix, Deferred, or N/A yourself.

This skill is a resolver and coordinator, not a review producer and not a single-issue fixer:

- `pr-review-and-document` creates or updates review findings.
- `codex-review-pass` produces read-only review bundles.
- `codex-fix-worker` fixes exactly one selected issue with bounded owned files and reports results back to the resolver.
- `pr-review-resolver` reads unresolved issues, asks the user how to handle each one, coordinates fix workers or inline status decisions, and updates the canonical review comment.

Use `.pr-review-cache/pr-#.json` as the only review state file. Do not create extra cache files or PR comments. Do not commit, push, merge, or directly call `gh api` to update comments.

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
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-sync.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-replace.sh"
```

Before beginning the interactive loop, read `references/interaction-example.md`.

## Workflow

1. Get the PR number with `get-pr-number.sh`.
2. Read the canonical review comment:

   ```bash
   set +e
   REVIEW_CONTENT=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh" "$PR_NUMBER")
   rc=$?
   set -e

   case $rc in
     0) ;;
     2) echo "No canonical review comment found. Run pr-review-and-document first." >&2; exit 2 ;;
     *) echo "cache-read-comment.sh failed with exit $rc" >&2; exit "$rc" ;;
   esac
   ```

3. Extract the cache `content_hash` for CAS and validate it locally before relying on it. The snippet pins shell flags, checks file existence before invoking jq, and surfaces the recovery script's rc:

   ```bash
   set -euo pipefail
   CACHE_FILE=".pr-review-cache/pr-${PR_NUMBER}.json"

   if [ ! -f "$CACHE_FILE" ]; then
     echo "Cache file missing: $CACHE_FILE — refreshing from GitHub..." >&2
     if ! "${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-sync.sh" "$PR_NUMBER"; then
       echo "Cache recovery failed (cache-sync.sh rc=$?). Manual intervention required." >&2
       exit 2
     fi
     exit 2
   fi

   EXPECTED_CONTENT_HASH=$(jq -r '.content_hash // ""' "$CACHE_FILE")
   if ! [[ "$EXPECTED_CONTENT_HASH" =~ ^sha256:[0-9a-f]{64}$ ]]; then
     echo "Cache content_hash is missing or malformed: '$EXPECTED_CONTENT_HASH'. Refreshing cache from GitHub..." >&2
     if ! "${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-sync.sh" "$PR_NUMBER"; then
       echo "Cache recovery failed (cache-sync.sh rc=$?). Manual intervention required." >&2
       exit 2
     fi
     exit 2
   fi
   ```

   `cache-write-comment.sh:36-44` enforces the same regex at write-time, but checking at extract-time gives a clearer error and triggers the documented recovery (`cache-sync.sh` re-fetches the canonical comment from GitHub) rather than failing late inside the write pipeline.
4. Parse unresolved items from the review content.
5. For each unresolved issue, one at a time:
   - Present the issue in Traditional Chinese.
   - Show source (`Claude`, `Gemini`, or `Codex`), title, file references, problem, and fix suggestion.
   - Read the referenced source files and verify whether the issue still exists.
   - Explain available options in Traditional Chinese.
   - Ask the user to choose: Fix, Deferred, N/A, or Skip for now.
   - Wait for the user's decision before moving to the next issue.
**Session setup (perform once, before any fix-worker dispatch in Step 6).** Initialize the session-scoped `OWNED_FILES` bash array that Step 9's scope check reads. Without this, Step 9 either errors under `set -u` ("OWNED_FILES[@]: parameter not set") or silently fail-opens under `set +u`:

```bash
declare -a OWNED_FILES=()
```

6. For user-approved fixes:
   - Identify owned files from the issue and source inspection.
   - Check for overlap with any in-progress fix worker. Do not run two workers with overlapping owned files concurrently.
   - Spawn or invoke bounded fix work using the managed-only `codex-fix-worker` contract. Provide PR number, source, issue title, file references, user decision, and owned files.
   - Track `{issue title, source, owned files, worker id/status}` in memory.
   - Append the worker's owned files to the session-scoped `OWNED_FILES` array (initialized in Session setup above):

     ```bash
     # Each time a fix-worker is dispatched with owned files A B C:
     OWNED_FILES+=(A B C)
     ```

   - Continue discussing later issues only when doing so does not require the same files.
7. For Deferred or N/A decisions:
   - Record the reason from the user.
   - Add a self-contained source comment near the relevant code when appropriate:
     ```text
     Design Decision: <complete reason; do not rely on PR links>
     ```
   - Mark the item as `⏭️ Deferred` or `⏭️ N/A` in the planned comment update.
8. After all issues have decisions, collect fix worker results. Parse the worker's `Status:` line (see `codex-fix-worker` Output Contract); do not infer success from the presence of `Files changed:` alone:
   - `Status: success`: mark only that issue as `✅ Fixed` and include a concise fix/validation note.
   - `Status: partial`: report the validation gap in Traditional Chinese and ask the user whether to accept-as-fixed, retry, or defer.
   - `Status: failed`: report the error in Traditional Chinese and ask whether to retry, defer, or mark N/A. Do not mark `✅ Fixed`.
9. Validate modified file scope. Default `git diff --name-only` misses untracked new files and renames; with default `core.quotePath=true` it also escapes non-ASCII paths (e.g. `"T\303\251dious file.txt"`), which would silently false-positive against the raw paths in `OWNED_FILES`. Use the portable sequence below so an out-of-scope worker write cannot pass silently and so non-ASCII paths and macOS BSD `awk` both work correctly:

   ```bash
   # Defensive guard: if OWNED_FILES wasn't maintained per Step 6, fail loudly
   # with a clear message instead of producing a confusing "every file is
   # unexpected" abort or (under set -u) an "unbound variable" crash.
   if [ "${#OWNED_FILES[@]:-0}" -eq 0 ]; then
     echo "BUG: OWNED_FILES is empty. Step 6 must accumulate owned files via OWNED_FILES+=(...)." >&2
     echo "Aborting scope check to avoid false-positive 'every file is unexpected'." >&2
     exit 2
   fi

   # Tracked-but-modified paths. `-c core.quotePath=false` keeps non-ASCII paths
   # in their raw UTF-8 form (matching OWNED_FILES); `-z` + `tr '\0' '\n'` is
   # NUL-safe for spaces and quotes. We use --no-renames so renames appear as
   # delete+add — that way both endpoints are visible and OWNED_FILES must list
   # whichever side the worker is allowed to touch.
   TRACKED=$(git -c core.quotePath=false diff -z --name-only --no-renames HEAD | tr '\0' '\n')

   # Untracked paths via NUL-delimited porcelain v1: each record is `XY path\0`,
   # so we use `tr '\0' '\n'` first to convert to lines, then awk's substr to
   # strip the 3-char status prefix (`??` + space). The earlier `awk -v RS='\0'`
   # form was broken on macOS/BSD awk (RS='\0' is interpreted as empty RS aka
   # paragraph mode, collapsing the entire stream to one record), so only the
   # first untracked file was emitted. Using `tr` first is portable.
   UNTRACKED=$(git -c core.quotePath=false status -z --porcelain \
                 | tr '\0' '\n' \
                 | awk '/^\?\? / { print substr($0, 4) }')

   ACTUAL=$(printf '%s\n%s\n' "$TRACKED" "$UNTRACKED" | sort -u | sed '/^$/d')

   # OWNED_FILES is the array maintained in Step 6 across all worker dispatches.
   # `${OWNED_FILES[@]:-}` survives `set -u` in case the guard above is ever
   # removed; the `sed '/^$/d'` strips the empty entry that ${arr[@]:-} produces.
   EXPECTED=$(printf '%s\n' "${OWNED_FILES[@]:-}" | sort -u | sed '/^$/d')

   UNEXPECTED=$(comm -23 <(printf '%s\n' "$ACTUAL") <(printf '%s\n' "$EXPECTED"))
   if [ -n "$UNEXPECTED" ]; then
     echo "Unexpected files changed (not in any worker's owned set):" >&2
     # Quote to preserve spaces in filenames in the diagnostic output.
     while IFS= read -r f; do
       printf '  %s\n' "$f" >&2
     done <<< "$UNEXPECTED"
     # Stop and ask the user before continuing.
     exit 2
   fi
   ```

   **Rename note:** the `--no-renames` flag makes a `git mv a.txt b.txt` appear as deletion of `a.txt` + addition of `b.txt`. If a worker is expected to perform a rename, its `OWNED_FILES` declaration must include both endpoints.

10. Update the canonical review comment:
    - Preserve all existing Claude, Gemini, and Codex issue sections.
    - Preserve all issue text except the specific status/fix summary for resolved items.
    - Treat untagged issues as Claude issues.
    - Keep `review_round` unchanged.
    - Update status indicators, summary counts, `updated_at`, and metadata `last_writer`.
    - Upgrade metadata:

      ```bash
      METADATA_JSON=$(printf '%s\n' "$REVIEW_CONTENT" \
        | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-upgrade.sh" \
            --stdin --last-writer pr-review-resolver)
      ```

    - After editing `$METADATA_JSON` (e.g. via `jq`), replace only the hidden metadata block. `review-metadata-replace.sh` requires a metadata JSON file path; pipe the comment over stdin:

      ```bash
      METADATA_FILE=$(mktemp)
      trap 'rm -f "$METADATA_FILE"' EXIT
      printf '%s' "$METADATA_JSON" > "$METADATA_FILE"

      UPDATED_CONTENT=$(printf '%s\n' "$REVIEW_CONTENT" \
        | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/review-metadata-replace.sh" \
            --stdin --metadata-file "$METADATA_FILE")
      ```

    - Write through `cache-write-comment.sh`:

      ```bash
      printf '%s\n' "$UPDATED_CONTENT" \
        | "${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh" \
            --stdin "$PR_NUMBER" --expected-content-hash "$EXPECTED_CONTENT_HASH"
      ```

11. Handle `cache-write-comment.sh` exit codes (see `cache-write-comment.sh:22-25`):
    - `0`: success.
    - `1`: covers two distinct failure modes — disambiguate by inspecting the `stale_source_id` flag. Pin shell flags, check file existence first, and capture jq's rc so a missing or unreadable cache file cannot silently take the wrong branch:

      ```bash
      set -euo pipefail
      CACHE_FILE=".pr-review-cache/pr-${PR_NUMBER}.json"

      if [ ! -f "$CACHE_FILE" ]; then
        echo "Cache file vanished between write and post-write inspection: $CACHE_FILE" >&2
        exit 1
      fi

      if ! STALE=$(jq -r '.stale_source_id // false' "$CACHE_FILE" 2>&1); then
        echo "jq failed reading $CACHE_FILE: $STALE" >&2
        exit 1
      fi

      if [ "$STALE" = "true" ]; then
        echo "Post-sync cache repair failed; recover with ${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-sync.sh \"$PR_NUMBER\"" >&2
      else
        echo "GitHub sync failed but local cache is up to date." >&2
        echo "Retry with: ${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh --sync-from-cache \"$PR_NUMBER\"" >&2
      fi
      ```

    - `2`: local error; abort.
    - `3`: remote is newer; re-fetch with `${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-sync.sh "$PR_NUMBER"` (it does a force-refresh internally), then redo Steps 2-10 against the fresh content.
    - `4`: CAS hash mismatch. Re-run Step 2 (`cache-read-comment.sh`) to refresh `$REVIEW_CONTENT`, re-run Step 3 to recapture and re-validate `EXPECTED_CONTENT_HASH`, re-apply only this resolver session's status updates to the newer content, and retry once. If the retry also exits `4`, report `CAS conflict: another writer holds the lock` and stop.
12. Consider whether resolved decisions should update durable project guidance such as `AGENTS.md`, `CLAUDE.md`, or docs. Ask the user before making guidance changes.

## Unresolved Item Detection

Treat these as unresolved:

- Details summaries or issue headings with `⚠️` or `🔴`.
- `[Codex]` or `[Gemini]` issues with `⚠️` or `🔴`.
- Table rows with `⚠️ Pending`.
- Details summaries without `✅` or `⏭️`.
- Action Plan items with unchecked `[ ]`.

Treat these as resolved:

- `✅ Fixed`, `✅ Resolved`, or equivalent fixed status.
- `⏭️ Deferred`, `⏭️ N/A`, `⏭️ Duplicate`, or other explicit skipped status.
- Checked Action Plan items `[x]`.

Source rules:

- `[Codex]` means Codex review pass.
- `[Gemini]` means Gemini Code Assist integration.
- No source prefix means Claude for backward compatibility.

## User Interaction Requirements

For each issue, use this shape in Traditional Chinese:

```text
問題 X/Y：<title>

來源：Codex / Gemini / Claude
位置：path/to/file.ts:42
狀態：仍需處理 / 可能已修復 / 需要確認

問題摘要：
<explain the issue and impact>

可選處理方式：
1. 修復：<specific approach>
2. 延後：<when this is acceptable>
3. 標記 N/A：<when this is acceptable>
4. 暫時跳過：稍後再回來處理
```

Do not continue to the next issue until the user chooses.

## Relationship To codex-fix-worker

`codex-fix-worker` is not the resolver. Use it only after the user chooses Fix for a specific issue and owned files are known. It is always resolver-managed: it edits code and reports validation, but never updates review comments or `.pr-review-cache`.

The resolver remains responsible for the user-facing discussion, conflict coordination, final status table, Deferred/N/A decisions, and all canonical review comment updates.

## Comment Update Rules

- Use `cache-write-comment.sh`; never use `gh api` directly.
- Do not use `--local-only`.
- Preserve `review_sources` for Claude, Gemini, and Codex.
- Preserve `[Codex]` and `[Gemini]` labels.
- Keep existing `review_round` unchanged.
- Update summary counters so totals/fixed/remaining match canonical sections.
- Add a concise resolver note only when it clarifies a user decision or validation result.

## Output Contract

End with:

```text
PR review resolver:
- PR: #123
- Processed issues: N
- Fixed: N
- Deferred: N
- N/A: N
- Skipped: N

Files changed:
- path/to/file.ts

Validation:
- command and result

Review comment:
- Updated via .pr-review-cache/pr-123.json
- Comment URL: ...

Remaining:
- ...
```
