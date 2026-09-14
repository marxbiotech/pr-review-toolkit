---
name: grok-review-pass
description: Use when asked to run a Grok PR review pass, especially a parallel six-agent review. This skill orchestrates read-only subagents for comments, tests, error handling, type design, general code quality, and simplification, then returns one deduplicated review bundle for pr-review-and-document to publish. Use when the user runs /grok-review-pass.
---

# Grok Review Pass

Run a Grok PR review pass by launching six read-only subagents, collecting their findings, and returning one normalized review bundle.

## Contract

This skill is the review producer only. It must not write `.pr-review-cache`, create or update PR comments, commit, push, or call `cache-write-comment.sh`. The Grok `pr-review-and-document` skill owns cache/comment reads, writes, metadata updates, CAS retry, and GitHub publication.

Run this skill in the parent Grok session. Do not spawn it as a nested subagent; Grok subagents cannot spawn children.

Use the current repository diff, PR diff, and existing review content supplied by the caller as context. If the caller did not supply enough context, gather read-only context with `git diff`, `git status`, and helper reads only.

Find the toolkit root in this order:

1. Use `GROK_PLUGIN_ROOT` when set (Grok plugin runtime). Assign it to `PR_REVIEW_TOOLKIT_ROOT`.
2. Use `PR_REVIEW_TOOLKIT_ROOT` when already set. This is the supported path for source installs.
3. If both are unset, derive the packaged plugin root from the skill path. This SKILL.md lives at `<root>/skills/<skill-name>/SKILL.md`, so `<root>` is exactly two levels up:

   ```bash
   : "${SKILL_PATH:?SKILL_PATH must be set to the absolute path of this SKILL.md}"
   PR_REVIEW_TOOLKIT_ROOT="$(cd "$(dirname "$SKILL_PATH")/../.." && pwd)"
   ```

   Verify both `<root>/.grok-plugin/plugin.json` and `<root>/scripts/cache-read-comment.sh` exist. If either is missing, treat derivation as failed and proceed to step 4.
4. Stop and ask for `GROK_PLUGIN_ROOT` or `PR_REVIEW_TOOLKIT_ROOT`.

Canonicalize the root before using helper scripts:

```bash
PR_REVIEW_TOOLKIT_ROOT="$(cd "$PR_REVIEW_TOOLKIT_ROOT" && pwd)"
```

Do not use `${CLAUDE_PLUGIN_ROOT}`.

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
  exit 2
fi
```

## Workflow

1. Determine PR context. Prefer caller-provided PR number, base branch, head SHA, existing review content, and changed files. If missing, use `get-pr-number.sh`, `cache-read-comment.sh`, `git status`, and `git diff` read-only commands.
2. Build one shared review packet for subagents containing changed files, relevant diff, existing unresolved findings, repository instructions, and any user-requested aspects.
3. The six review agents live at `${PR_REVIEW_TOOLKIT_ROOT}/agents/`:
   - `code-reviewer.md`
   - `code-simplifier.md`
   - `silent-failure-hunter.md`
   - `type-design-analyzer.md`
   - `pr-test-analyzer.md`
   - `comment-analyzer.md`
4. Spawn six read-only subagents in parallel with `spawn_subagent`. For each agent:

   - `subagent_type`: `pr-review-toolkit:<agent-name>` when the plugin agent is available.
   - If that type is not available, use `explore` (read-only) and include the full body of `${PR_REVIEW_TOOLKIT_ROOT}/agents/<agent-name>.md` in the prompt.
   - `background`: `true`
   - `isolation`: `none`
   - `prompt`: the shared review packet plus the instruction to return findings only.

5. Each subagent must return findings only. Subagents must not edit files, write cache files, post comments, run `gh api`, or update metadata.
6. Wait for all six with `get_command_or_subagent_output`. If one fails, include a non-canonical follow-up note naming the failed aspect; do not silently omit it. Always emit the `Agents completed:` line as the actually-successful set so `pr-review-and-document` can refuse to publish a partial bundle.
7. Aggregate results:
   - Drop duplicates already present in the existing review comment, including `[Claude]`, `[Gemini]`, `[Codex]`, and `[Grok]` issues.
   - Merge duplicates between subagents into one finding with all relevant sources listed.
   - Keep only actionable findings with concrete file references and fixes.
   - Classify each finding as `critical`, `important`, or `suggestion`.
   - Generate stable finding IDs (see Finding Format below).
8. Return the normalized review bundle described below. Do not publish it.

## Finding Format

Return findings in this normalized shape:

```text
id: grok:<file>:<symbol-or-nearest-heading>:<diagnostic-kind>:<snippet-hash>
severity: critical | important | suggestion
sources: code-reviewer[, pr-test-analyzer, ...]
title: short issue title
file: path/to/file.ts:42
problem: concise explanation
fix: concrete recommended change
```

Finding ID grammar (used as the dedup key in `review_sources.grok.posted_finding_ids`):

- Prefix is the literal string `grok`.
- `<file>` is the repo-relative path of the issue. Repo paths in this project do not contain `:`; if a future producer needs to embed paths that may contain `:`, percent-encode the `:` (`%3A`) so the colon delimiter remains unambiguous.
- `<symbol-or-nearest-heading>` is the smallest enclosing function, class, or markdown heading. If none applies, use the literal `_`.
- `<diagnostic-kind>` is the kebab-case category emitted by the subagent (e.g. `error-handling`, `type-design`, `comment-accuracy`).
- `<snippet-hash>` is the first 8 lowercase hex chars of `sha1` over the whitespace-collapsed text of the smallest enclosing statement or paragraph. The hash is intentionally line-number-independent so trivial reflow does not invalidate the ID.

Finding IDs are best-effort. If a duplicate slips through, mark it as duplicate only when the dev agent or resolver asks.

## Output Contract

End with:

```text
Grok review bundle:
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

**Bundle format invariants (consumed by `pr-review-and-document`):**

- "Physical line" means a sequence of bytes terminated by a single LF (`\n`), with no embedded CR, no trailing CR, and no Unicode line-separator characters (U+2028, U+2029).
- The `- Agents completed:` line SHOULD be emitted as a single physical line. Names are comma-separated; whitespace around commas is allowed.
- The consumer in `pr-review-and-document` tolerates indented continuation lines (lines starting with whitespace) as defense-in-depth.
- Nested entries under `- New findings:`, `- Strengths:`, `- Type ratings:`, `- Follow-up notes:` are indented continuation bullets and may wrap freely.

`pr-review-and-document` is responsible for converting this bundle into canonical markdown sections and writing it to the PR.
