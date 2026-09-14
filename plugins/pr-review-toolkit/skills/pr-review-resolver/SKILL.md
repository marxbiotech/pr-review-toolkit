---
name: pr-review-resolver
description: Use when asked to resolve, address, process, or discuss PR review findings with Grok. This skill is an interactive Traditional Chinese resolver that reads the canonical pr-review-toolkit comment, handles unresolved Claude/Gemini/Codex/Grok issues one by one with user decisions, coordinates bounded fix work, and updates review status through .pr-review-cache/pr-#.json. Use when the user runs /pr-review-resolver.
---

# PR Review Resolver

Interactively resolve unresolved PR review findings from the canonical pr-review-toolkit comment.

## Contract

Always communicate with the user in Traditional Chinese (`zh-TW`). Process issues one at a time and wait for the user's decision for each issue. Do not decide Fix, Deferred, or N/A yourself. Use `ask_user_question` for the decision.

This skill is a resolver and coordinator, not a review producer and not a single-issue fixer:

- `pr-review-and-document` creates or updates review findings.
- `grok-review-pass` produces read-only review bundles.
- `grok-fix-worker` fixes exactly one selected issue with bounded owned files and reports results back to the resolver.
- `pr-review-resolver` reads unresolved issues, asks the user how to handle each one, coordinates fix workers or inline status decisions, and updates the canonical review comment.

Use `.pr-review-cache/pr-#.json` as the only review state file. Do not create extra cache files or PR comments. Do not commit, push, merge, or directly call `gh api` to update comments.

Find the toolkit root in this order:

1. Use `GROK_PLUGIN_ROOT` when set (Grok plugin runtime). Assign it to `PR_REVIEW_TOOLKIT_ROOT`.
2. Use `PR_REVIEW_TOOLKIT_ROOT` when already set. This is the supported path for source installs.
3. If both are unset, derive the packaged plugin root from the skill path. This SKILL.md lives at `<root>/skills/<skill-name>/SKILL.md`, so `<root>` is exactly two levels up:

   ```bash
   : "${SKILL_PATH:?SKILL_PATH must be set to the absolute path of this SKILL.md}"
   PR_REVIEW_TOOLKIT_ROOT="$(cd "$(dirname "$SKILL_PATH")/../.." && pwd)"
   ```

   Verify both `<root>/.grok-plugin/plugin.json` and `<root>/scripts/cache-write-comment.sh` exist. If either is missing, treat derivation as failed and proceed to step 4.
4. Stop and ask for `GROK_PLUGIN_ROOT` or `PR_REVIEW_TOOLKIT_ROOT`.

Canonicalize the root before using helper scripts:

```bash
PR_REVIEW_TOOLKIT_ROOT="$(cd "$PR_REVIEW_TOOLKIT_ROOT" && pwd)"
```

Do not use `${CLAUDE_PLUGIN_ROOT}`.

Use only these scripts for review state:

```bash
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/get-pr-number.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-write-comment.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-sync.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/extract-content-hash.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/disambiguate-stale-source.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/check-fix-worker-scope.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/parse-validation-entry.sh"
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

3. Extract the cache `content_hash` for CAS via the shared helper:

   ```bash
   set +e
   EXPECTED_CONTENT_HASH=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/extract-content-hash.sh" "$PR_NUMBER")
   rc=$?
   set -e

   case $rc in
     0) ;;
     2) echo "Cache was refreshed; re-read REVIEW_CONTENT and retry from Step 2." >&2; exit 2 ;;
     *) exit "$rc" ;;
   esac
   ```

   Unit-tested in `tests/extract-content-hash-test.sh`.
4. Parse unresolved items from the review content.
5. For each unresolved issue, one at a time:
   - Present the issue in Traditional Chinese.
   - Show source (`Claude`, `Gemini`, `Codex`, or `Grok`), title, file references, problem, and fix suggestion.
   - Read the referenced source files and verify whether the issue still exists.
   - Explain available options in Traditional Chinese.
   - Ask the user with `ask_user_question` to choose: Fix, Deferred, N/A, or Skip for now.
   - Wait for the user's decision before moving to the next issue.
6. For user-approved fixes:
   - **Session setup (once per resolver session, before the first fix-worker dispatch):** initialize the session-scoped `OWNED_FILES` bash array that Step 9's scope check reads:

     ```bash
     declare -a OWNED_FILES=()
     ```

     If this resolver session is resumed in a fresh shell (model context reset, new bash subshell), the `OWNED_FILES` array state is lost. The only safe action then is to abort this session and restart from Step 1; do NOT re-declare `OWNED_FILES=()` and continue.

   - Identify owned files from the issue and source inspection.
   - Check for overlap with any in-progress fix worker. Do not run two workers with overlapping owned files concurrently.
   - Spawn bounded fix work with `spawn_subagent`. Use `subagent_type: general-purpose`, `background: true`, `isolation: none`. Load `${PR_REVIEW_TOOLKIT_ROOT}/skills/grok-fix-worker/SKILL.md` into the prompt and provide PR number, source, issue title, file references, user decision, and owned files.
   - Track `{issue title, source, owned files, worker id/status}` in memory.
   - Append the worker's owned files to the session-scoped `OWNED_FILES` array:

     ```bash
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
8. After all issues have decisions, collect fix worker results with `get_command_or_subagent_output`. Parse the worker's `Status:` line (see `grok-fix-worker` Output Contract); do not infer success from the presence of `Files changed:` alone:
   - `Status: success`: cross-check every `Validation:` entry by passing it to `${PR_REVIEW_TOOLKIT_ROOT}/scripts/parse-validation-entry.sh '<entry>'`. The parser distinguishes two valid shapes by its first stdout line:

     1. Run the parser; capture its rc. If rc != 0, the entry is malformed — treat the entire worker output as `partial`.
     2. Read the parser's first stdout line. If it equals the literal `none-possible`, this is a form-2 entry (`none possible: <reason>`) and counts as success-eligible — proceed to the next entry without further check.
     3. Otherwise interpret the first stdout line as a signed integer rc. If rc == 0, the entry counts as success-eligible. If rc != 0, treat the entire worker output as `partial`.
     4. Only mark `✅ Fixed` when every entry survives steps 1-3 as success-eligible.

     Workers that violate the safety net (em-dash separator, malformed shape, hidden non-zero exit, whitespace-only cmd, multiple `-- exit` boundaries) are rejected by the parser at step 1; their `Status: success` self-report does not bypass the cross-check.
   - `Status: partial`: report the validation gap in Traditional Chinese and ask the user whether to accept-as-fixed, retry, or defer.
   - `Status: failed`: report the error in Traditional Chinese and ask whether to retry, defer, or mark N/A. Do not mark `✅ Fixed`.
9. Validate modified file scope via the shared helper:

   ```bash
   if [ -z "${OWNED_FILES[@]+x}" ] || [ "${#OWNED_FILES[@]}" -eq 0 ]; then
     echo "BUG: OWNED_FILES is unset or empty." >&2
     echo "Session setup in Step 6 must declare OWNED_FILES=() and step 6 must accumulate" >&2
     echo "owned files via OWNED_FILES+=(...) for each fix-worker dispatch." >&2
     echo "If this resolver session was resumed in a fresh shell, the array state is lost;" >&2
     echo "abort this session and restart from Step 1 rather than continuing with an empty array." >&2
     exit 2
   fi

   "${PR_REVIEW_TOOLKIT_ROOT}/scripts/check-fix-worker-scope.sh" "${OWNED_FILES[@]}"
   ```

   The helper is unit-tested in `tests/check-fix-worker-scope-test.sh`. See [`scripts/check-fix-worker-scope.sh`](../../../../scripts/check-fix-worker-scope.sh).

   **Rename note:** the helper passes `--no-renames` to git, so `git mv a.txt b.txt` appears as deletion of `a.txt` + addition of `b.txt`. If a worker is expected to perform a rename, its `OWNED_FILES` declaration must include both endpoints.

   If no fix worker ran (every issue was Deferred, N/A, or skipped), skip this scope check.

10. Update the canonical review comment:
    - Preserve all existing Claude, Gemini, Codex, and Grok issue sections.
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

    - After editing `$METADATA_JSON` (e.g. via `jq`), replace only the hidden metadata block:

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
    - `1`: covers two distinct failure modes — disambiguate via the shared helper:

      ```bash
      set +e
      "${PR_REVIEW_TOOLKIT_ROOT}/scripts/disambiguate-stale-source.sh" "$PR_NUMBER"
      disambig_rc=$?
      set -e

      case $disambig_rc in
        1)  exit 1 ;;
        10) echo "Cannot disambiguate cache-write-comment.sh exit 1 cause; manual intervention required." >&2; exit 10 ;;
        *)  echo "disambiguate-stale-source.sh exited unexpectedly (rc=$disambig_rc)" >&2; exit "$disambig_rc" ;;
      esac
      ```

      Unit-tested in `tests/disambiguate-stale-source-test.sh`.

    - `2`: local error; abort.
    - `3`: remote is newer; re-fetch with `${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-sync.sh "$PR_NUMBER"`, then redo Steps 2-10 against the fresh content.
    - `4`: CAS hash mismatch. Re-run Step 2 (`cache-read-comment.sh`) to refresh `$REVIEW_CONTENT`, re-run Step 3 to recapture and re-validate `EXPECTED_CONTENT_HASH`, re-apply only this resolver session's status updates to the newer content, and retry once. If the retry also exits `4`, report `CAS conflict: another writer holds the lock` and stop.
12. Consider whether resolved decisions should update durable project guidance such as `AGENTS.md`, `CLAUDE.md`, or docs. Ask the user before making guidance changes.

## Unresolved Item Detection

Treat these as unresolved:

- Details summaries or issue headings with `⚠️` or `🔴`.
- `[Codex]`, `[Gemini]`, or `[Grok]` issues with `⚠️` or `🔴`.
- Table rows with `⚠️ Pending`.
- Details summaries without `✅` or `⏭️`.
- Action Plan items with unchecked `[ ]`.

Treat these as resolved:

- `✅ Fixed`, `✅ Resolved`, or equivalent fixed status.
- `⏭️ Deferred`, `⏭️ N/A`, `⏭️ Duplicate`, or other explicit skipped status.
- Checked Action Plan items `[x]`.

Source rules:

- `[Grok]` means Grok review pass.
- `[Codex]` means Codex review pass.
- `[Gemini]` means Gemini Code Assist integration.
- No source prefix means Claude for backward compatibility.

## User Interaction Requirements

For each issue, use this shape in Traditional Chinese:

```text
問題 X/Y：<title>

來源：Grok / Codex / Gemini / Claude
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

## Relationship To grok-fix-worker

`grok-fix-worker` is not the resolver. Use it only after the user chooses Fix for a specific issue and owned files are known. It is always resolver-managed: it edits code and reports validation, but never updates review comments or `.pr-review-cache`.

The resolver remains responsible for the user-facing discussion, conflict coordination, final status table, Deferred/N/A decisions, and all canonical review comment updates.

## Comment Update Rules

- Use `cache-write-comment.sh`; never use `gh api` directly.
- Do not use `--local-only`.
- Preserve `review_sources` for Claude, Gemini, Codex, and Grok.
- Preserve `[Codex]`, `[Gemini]`, and `[Grok]` labels.
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
