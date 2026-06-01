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
4. Run targeted validation such as tests, lint, `git diff --check`, script syntax checks, or framework-specific checks relevant to the changed files. Capture each validation command and its exit code. If no validation is possible for this change (e.g. pure documentation edit, no covering test exists), say so explicitly under `Validation:` — never leave it empty.
5. Compute the `Status:` field per the contract below and report files changed, validation results, fix summary, status, and remaining risk to `pr-review-resolver`.

Do not update metadata. Do not mark the review issue as fixed. Do not write the canonical review comment. The resolver will update status after it reviews this worker's result.

## Output Contract

End with:

```text
Files changed:
- path/to/file.ts

Validation:
- <command> -- exit <N>
- <command> -- exit <N>
- (or) none possible: <reason>

Status: success | partial | failed

Fix summary:
- ...

Review comment update:
- None. pr-review-resolver must update the canonical review comment.

Commit message draft:
fix(scope): address issue title

Remaining risk:
- ...
```

`Validation:` entry shape — each entry is exactly one of:

- `<command> -- exit <N>` — a real validation command and its captured exit code. The separator is the ASCII double-dash ` -- ` (space + two hyphens + space) to keep encoding-stable and easy to regex (`/^- (.*) -- exit (-?\d+)$/`); do not use Unicode em-dash. Commands containing the literal ` -- ` substring should be quoted (e.g. `'bash -c "..."` ` instead of bare).
- `none possible: <reason>` — an explicit statement that no validation applies, with `<reason>` explaining why (e.g. "comment-only edit" or "no covering test exists in the repo").

The grammar is unit-tested by `tests/parse-validation-entry-test.sh` (12 cases) and parsed at the consumer side by `${PR_REVIEW_TOOLKIT_ROOT}/scripts/parse-validation-entry.sh`. Workers should follow the grammar exactly; the resolver invokes the parser to decide success-eligibility (see `pr-review-resolver` step 8).

`Status` semantics — the resolver parses this line and uses it to decide whether to mark `✅ Fixed`:

- `success`: the change addresses the issue and every `Validation:` entry is either `-- exit 0` or `none possible: <reason>`. A mix is allowed — e.g. a doc edit that also passes `git diff --check` reports both forms and is `success`.
- `partial`: the change addresses the issue but at least one validation entry has exit code != 0, was skipped/aborted partway, failed to start (command not found, environment unavailable), or completed with only partial coverage. Explain the gap in `Remaining risk`. `none possible: <reason>` entries do NOT count as "attempted".
- `failed`: the change does not address the issue (e.g. could not be applied within owned files, attempted fix introduced a regression).

**Safety net — never report `Status: success` when:**
- any `Validation:` entry has a non-zero exit code, OR
- a validation command was attempted but its true exit code could not be captured (worker forgot `set -o pipefail` and only saw the rc of a pipeline tail, the command was backgrounded without `wait`, a wrapper script swallowed the inner rc). Use `partial` and explain the rc-capture gap in `Remaining risk`.

The resolver treats `partial` as "ask the user" and `failed` as "do not mark fixed".

**Caveat: `partial` is overloaded by design.** After the resolver's cross-check via `parse-validation-entry.sh`, a worker output may be demoted to `partial` for one of two reasons:

1. **Worker self-reported `partial`** — the worker explicitly acknowledged a gap.
2. **Worker self-reported `success` but failed the cross-check** — the worker emitted a malformed `Validation:` entry, an em-dash separator, a hidden non-zero exit, or a whitespace-only command, and the resolver refused to honor the success claim.

Both manifest identically as `Status: partial` in the resolver's downstream handling. If a future workflow needs to distinguish "trust worker, validation incomplete" from "worker lied, cross-check caught it", add a `partial-cross-check-demoted` flag or split into separate enum values.

**Untested adjacent contract**: the bundle `Agents completed:` parser (in `pr-review-and-document/SKILL.md` step 4) uses an inline awk script that is not extracted to its own script and has no unit-test coverage for the `printed` sentinel + END guard double-print fix. A future regression that drops either of those guards would produce duplicate output that the downstream `sort -u` masks. Extraction to `scripts/parse-agents-completed.sh` with fixture tests is the next prose-to-script extraction target.

The resolver, dev agent, or human is responsible for committing and pushing. Do not start another review pass before the code changes are committed or intentionally left uncommitted by the dev agent.
