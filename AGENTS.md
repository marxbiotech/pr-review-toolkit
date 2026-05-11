# Repository Guidelines

## Project Structure & Module Organization

This repository is a Claude Code plugin for PR review workflows with companion Codex packaging. Claude metadata lives in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`; Codex metadata lives in `.agents/plugins/marketplace.json` (marketplace entry) and `plugins/pr-review-toolkit/.codex-plugin/plugin.json` (plugin manifest, packaged under a non-root plugin directory so Codex's marketplace resolver accepts it). Keep all plugin version fields in sync. Claude skills are stored in `skills/<skill-name>/SKILL.md`, with supporting material under each skill's `references/` directory when needed. User-facing command docs live in `commands/`. Reusable shell utilities live in `scripts/`, with shared helpers in `scripts/lib/common.sh`. Workflow and release notes are documented in `docs/`, `README.md`, `CHANGELOG.md`, and `RELEASING.md`. GitHub Actions are in `.github/workflows/`.

**Authoritative vs. packaged scripts.** The `scripts/` directory is authoritative; CI (`validate.yml` and `release.yml`) keeps the packaged copies under `plugins/pr-review-toolkit/scripts/` byte-identical and mode-identical. When editing a helper, change both trees in the same commit, or sync via `rsync -a --delete scripts/ plugins/pr-review-toolkit/scripts/`. Each helper carries a header banner noting the duplication. Helper `# Usage:` strings are written helper-directory-relative (e.g. `./cache-read-comment.sh [PR_NUMBER]`), with `deploy-pr.sh` as the lone exception (repo-root form). For Codex-skill invocation, prefer the absolute form `${PR_REVIEW_TOOLKIT_ROOT}/scripts/<helper>.sh`.

### Codex Skills

Codex-facing skills live under `plugins/pr-review-toolkit/codex/skills/<skill-name>/SKILL.md`, parallel to the Claude `skills/` tree. They target Codex's skill runtime and resolve their toolkit root via the `${PR_REVIEW_TOOLKIT_ROOT}` environment variable rather than `${CLAUDE_PLUGIN_ROOT}`, and they execute the packaged helper scripts under `plugins/pr-review-toolkit/scripts/`, which CI keeps byte-identical to the authoritative copies in `scripts/`. Currently shipped: `codex-review-pass` (review producer with bootstrap and append modes) and `codex-fix-worker` (bounded per-issue fix skill invoked by the dev agent). The Codex marketplace entry points to the packaged plugin directory `./plugins/pr-review-toolkit`, and the Codex plugin manifest points `skills` to `./codex/skills/` (relative to that plugin root); keep both paths stable when moving files. See `README.md` for source-install steps and `docs/codex-integration-design.md` for the contract.

## Build, Test, and Development Commands

There is no compile step; this project is Markdown, JSON, and Bash.

- `bash -n scripts/*.sh scripts/lib/*.sh`: syntax-check shell scripts.
- `jq empty .claude-plugin/plugin.json .claude-plugin/marketplace.json .agents/plugins/marketplace.json plugins/pr-review-toolkit/.codex-plugin/plugin.json`: validate plugin JSON.
- `./scripts/cache-sync.sh [PR_NUMBER]`: refresh the local `.pr-review-cache/` entry from GitHub.
- `./scripts/deploy-pr.sh`: deploy current branch changes through the project workflow.
- `git diff --check`: catch whitespace errors before committing.
- `SCRIPT_DIR=$PWD/plugins/pr-review-toolkit/scripts bash tests/<test-file>.sh`: run a test against the packaged Codex tree (CI exercises both trees automatically; the default `SCRIPT_DIR` is the authoritative root `scripts/`).

Most scripts require an authenticated GitHub CLI (`gh`) and should be run from the repository root.

**CI checks shared across workflows.** When the same validation needs to run in both `validate.yml` (per-PR) and `release.yml` (at tag time) — such as the script-tree parity check at `.github/actions/check-script-parity/` — extract it into a composite GitHub Action under `.github/actions/<name>/action.yml` rather than inlining identical bash in both workflows. Use a `runs: composite` block with an optional `inputs.error-prefix` so callers can prepend release-specific message prefixes (e.g. `Release blocked: `).

## Coding Style & Naming Conventions

Use Bash for scripts and Markdown for skills and docs. Shell scripts should start with `#!/bin/bash`, prefer `set -euo pipefail` for executable workflows, quote variable expansions, and keep portable macOS/Linux behavior where possible. Use two-space indentation in shell functions and JSON. Name scripts with lowercase kebab-case, such as `cache-read-comment.sh`; name skills with lowercase kebab-case directories.

## Testing Guidelines

Test suites live under `tests/*-test.sh` and are exercised by `validate.yml` against both `scripts/` and `plugins/pr-review-toolkit/scripts/`; see the `SCRIPT_DIR=... bash tests/<test-file>.sh` invocation above for running a single test locally (CI runs both trees automatically). Also validate changes with targeted command checks: run `bash -n` for edited scripts, `jq empty` for edited JSON, and execute the specific script path you changed when practical. For skill changes, review the trigger phrases and required tools in the edited `SKILL.md`, then verify any referenced scripts or files exist.

## Commit & Pull Request Guidelines

Recent history follows Conventional Commits, for example `fix(resolver): add missing allowed-tools` and `feat(cache): eliminate temp files with stdin pipe architecture`. Use `feat`, `fix`, `chore`, or `docs`, with an optional scope. PRs should include a concise summary, validation commands run, linked issues when applicable, and screenshots or pasted command output only when they clarify behavior. For release PRs, update `CHANGELOG.md` and keep `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `plugins/pr-review-toolkit/.codex-plugin/plugin.json` aligned.

## Security & Configuration Tips

Do not commit `.pr-review-cache/`, tokens, or local Claude/GitHub credentials. Treat GitHub comment payloads as external input and prefer `jq` or structured parsing over ad hoc text edits.
