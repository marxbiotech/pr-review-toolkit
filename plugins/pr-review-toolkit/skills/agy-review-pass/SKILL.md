---
name: agy-review-pass
description: Use when asked to run an Antigravity (AGY) PR review pass, especially a parallel six-agent review. This skill orchestrates read-only subagents for comments, tests, error handling, type design, general code quality, and simplification, then returns one deduplicated review bundle for pr-review-and-document to publish.
---

# Antigravity (AGY) Review Pass

Run an Antigravity (`agy`) PR review pass by launching six read-only subagents in parallel, collecting their findings, and returning one normalized review bundle.

## Contract

This skill is the review producer only. It must not write `.pr-review-cache`, create or update PR comments, commit, push, or call `cache-write-comment.sh`. The `pr-review-and-document` skill owns cache/comment reads, writes, metadata updates, CAS retry, and GitHub publication.

Use the current repository diff, PR diff, and existing review content supplied by the caller as context. If the caller did not supply enough context, gather read-only context with `git diff`, `git status`, and helper reads only.

Find the toolkit root in this order:

1. Use `AGY_PLUGIN_ROOT` when set by the Antigravity plugin runtime.
2. Use `GROK_PLUGIN_ROOT` when set by the Grok plugin runtime.
3. Use `PR_REVIEW_TOOLKIT_ROOT` when set in the environment.
4. If none is set, derive the packaged plugin root from the skill path. This `SKILL.md` lives at `<root>/skills/<skill-name>/SKILL.md`, so `<root>` is two levels up. In Antigravity, set `SKILL_PATH` to the exact path of this `SKILL.md` shown in `<skills>` (e.g. `~/.gemini/config/plugins/pr-review-toolkit/skills/agy-review-pass/SKILL.md` or `<repo>/plugins/pr-review-toolkit/skills/agy-review-pass/SKILL.md`) before running the snippet:

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

   Then verify `<root>/scripts/cache-write-comment.sh` exists and at least one of `<root>/.antigravity-plugin/plugin.json` or `<root>/.grok-plugin/plugin.json` exists. If missing, proceed to step 5.
5. Stop and ask the dev agent for `PR_REVIEW_TOOLKIT_ROOT`.

After resolving the root via steps 1-4, canonicalize it to an absolute path so that any subsequent `cd` in the calling workflow cannot invalidate it:

```bash
PR_REVIEW_TOOLKIT_ROOT="$(cd "$PR_REVIEW_TOOLKIT_ROOT" && pwd)"
```

The review pass may use only these helper scripts, and only for read-only context:

```bash
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/get-pr-number.sh"
"${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh"
```

Before running the workflow, verify the read-only helper scripts and six review agents are available:

```bash
: "${PR_REVIEW_TOOLKIT_ROOT:?Set PR_REVIEW_TOOLKIT_ROOT to the pr-review-toolkit plugin root}"

for helper in \
  get-pr-number.sh \
  cache-read-comment.sh; do
  if [ ! -x "${PR_REVIEW_TOOLKIT_ROOT}/scripts/${helper}" ]; then
    echo "Missing executable helper: ${PR_REVIEW_TOOLKIT_ROOT}/scripts/${helper}" >&2
    echo "Hint: PR_REVIEW_TOOLKIT_ROOT must point at the packaged plugin root" >&2
    echo "      (e.g. ~/.gemini/config/plugins/pr-review-toolkit or <repo>/plugins/pr-review-toolkit), not the repo root." >&2
    exit 2
  fi
done
if [ ! -r "${PR_REVIEW_TOOLKIT_ROOT}/scripts/lib/common.sh" ]; then
  echo "Missing readable shared library: ${PR_REVIEW_TOOLKIT_ROOT}/scripts/lib/common.sh" >&2
  exit 2
fi
for agent in \
  code-reviewer \
  code-simplifier \
  silent-failure-hunter \
  type-design-analyzer \
  pr-test-analyzer \
  comment-analyzer; do
  if [ ! -r "${PR_REVIEW_TOOLKIT_ROOT}/agents/${agent}.md" ]; then
    echo "Missing readable review agent: ${PR_REVIEW_TOOLKIT_ROOT}/agents/${agent}.md" >&2
    exit 2
  fi
done
```

## Workflow

1. Determine PR context. Prefer caller-provided PR number, base branch, head SHA, existing review content, and changed files. If missing, use `get-pr-number.sh`, `cache-read-comment.sh`, `git status`, and `git diff` read-only commands.
2. Build one shared review packet for subagents containing changed files, relevant diff, existing unresolved findings, repository instructions, and any user-requested aspects. Instruct subagents to emit `id_hint: agy:<file>:<symbol-or-heading>:<diagnostic-kind>:<snippet-hash>`.
3. Read all six agent definitions from `${PR_REVIEW_TOOLKIT_ROOT}/agents/`:
   - `code-reviewer.md`
   - `code-simplifier.md`
   - `silent-failure-hunter.md`
   - `type-design-analyzer.md`
   - `pr-test-analyzer.md`
   - `comment-analyzer.md`
4. Spawn six read-only subagents in parallel in a single turn using `invoke_subagent`:
   - If the plugin's custom agents (`code-reviewer`, `code-simplifier`, `silent-failure-hunter`, `type-design-analyzer`, `pr-test-analyzer`, `comment-analyzer`) are registered as subagent types in the current Antigravity session, invoke each by its `TypeName` with the shared review packet as `Prompt`.
   - Otherwise, invoke `invoke_subagent` six times with `TypeName: "research"` (Antigravity's built-in read-only research subagent), setting `Role` to the specialty (e.g. `"PR Code Reviewer"`, `"PR Code Simplifier"`, `"PR Silent Failure Hunter"`, `"PR Type Design Analyzer"`, `"PR Test Analyzer"`, `"PR Comment Analyzer"`) and `Prompt` to the full contents of `${PR_REVIEW_TOOLKIT_ROOT}/agents/<agent>.md` plus the shared review packet.
   - After launching all six subagents in parallel, end your turn (do not poll in a loop) so Antigravity's reactive wakeup delivers all six subagent responses.
5. Each subagent must return findings only. Subagents must not edit files, write cache files, post comments, run `gh api`, or update metadata.
6. Wait for all six subagents. If one fails, include a non-canonical follow-up note naming the failed aspect; do not silently omit it. Always emit the `Agents completed:` line as the actually-successful set so `pr-review-and-document` can refuse to publish a partial bundle.
7. Aggregate results:
   - Drop duplicates already present in the existing review comment.
   - Merge duplicates between subagents into one finding with all relevant sources listed.
   - Keep only actionable findings with concrete file references and fixes.
   - Classify each finding as `critical`, `important`, or `suggestion`.
   - Generate stable finding IDs with the `agy:` prefix (see Finding Format below).
8. Return the normalized review bundle described below. Do not publish it.

## Packaged Review Agents

The packaged agent files hold the full expert instructions for each review specialty:

```text
${PR_REVIEW_TOOLKIT_ROOT}/agents/code-reviewer.md
${PR_REVIEW_TOOLKIT_ROOT}/agents/code-simplifier.md
${PR_REVIEW_TOOLKIT_ROOT}/agents/silent-failure-hunter.md
${PR_REVIEW_TOOLKIT_ROOT}/agents/type-design-analyzer.md
${PR_REVIEW_TOOLKIT_ROOT}/agents/pr-test-analyzer.md
${PR_REVIEW_TOOLKIT_ROOT}/agents/comment-analyzer.md
```

## Finding Format

Return findings in this normalized shape:

```text
id: agy:<file>:<symbol-or-nearest-heading>:<diagnostic-kind>:<snippet-hash>
severity: critical | important | suggestion
sources: code-reviewer[, pr-test-analyzer, ...]
title: short issue title
file: path/to/file.ts:42
problem: concise explanation
fix: concrete recommended change
```

Finding ID grammar (used as the dedup key in `review_sources.agy.posted_finding_ids`):

- Prefix is the literal string `agy`.
- `<file>` is the repo-relative path of the issue. Repo paths in this project do not contain `:`; if a future producer needs to embed paths that may contain `:`, percent-encode the `:` (`%3A`) so the colon delimiter remains unambiguous.
- `<symbol-or-nearest-heading>` is the smallest enclosing function, class, or markdown heading. If none applies, use the literal `_`.
- `<diagnostic-kind>` is the kebab-case category emitted by the subagent (e.g. `error-handling`, `type-design`, `comment-accuracy`).
- `<snippet-hash>` is the first 8 lowercase hex chars of `sha1` over the whitespace-collapsed text of the smallest enclosing statement or paragraph. The hash is intentionally line-number-independent so trivial reflow does not invalidate the ID.

Finding IDs are best-effort. If a duplicate slips through, mark it as duplicate only when the dev agent or resolver asks.

## Output Contract

End with:

```text
AGY review bundle:
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

- "Physical line" means a sequence of bytes terminated by a single LF (`\n`), with no embedded CR, no trailing CR, and no Unicode line-separator characters (U+2028, U+2029). CRLF producers should normalize to LF before emitting the bundle.
- The `- Agents completed:` line SHOULD be emitted as a single physical line per the definition above. Names are comma-separated; whitespace around commas is allowed.
- The consumer in `pr-review-and-document` tolerates indented continuation lines (lines starting with whitespace) as defense-in-depth, concatenating them with the header line before parsing.
- All other top-level fields (`- PR number:`, `- Head SHA:`, `- New findings:`, etc.) also occupy a single physical line for their header.
- Nested entries under `- New findings:`, `- Strengths:`, `- Type ratings:`, `- Follow-up notes:` are indented continuation bullets and may wrap freely.

`pr-review-and-document` is responsible for converting this bundle into canonical markdown sections and writing it to the PR.
