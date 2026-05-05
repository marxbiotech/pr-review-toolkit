# Repository Guidelines

## Project Structure & Module Organization

This repository is a Claude Code plugin for PR review workflows. Plugin metadata lives in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`; keep their plugin version fields in sync. Skills are stored in `skills/<skill-name>/SKILL.md`, with supporting material under each skill's `references/` directory when needed. User-facing command docs live in `commands/`. Reusable shell utilities live in `scripts/`, with shared helpers in `scripts/lib/common.sh`. Workflow and release notes are documented in `docs/`, `README.md`, `CHANGELOG.md`, and `RELEASING.md`. GitHub Actions are in `.github/workflows/`.

## Build, Test, and Development Commands

There is no compile step; this project is Markdown, JSON, and Bash.

- `bash -n scripts/*.sh scripts/lib/*.sh`: syntax-check shell scripts.
- `jq empty .claude-plugin/plugin.json .claude-plugin/marketplace.json`: validate plugin JSON.
- `./scripts/cache-sync.sh [PR_NUMBER]`: refresh the local `.pr-review-cache/` entry from GitHub.
- `./scripts/deploy-pr.sh`: deploy current branch changes through the project workflow.
- `git diff --check`: catch whitespace errors before committing.

Most scripts require an authenticated GitHub CLI (`gh`) and should be run from the repository root.

## Coding Style & Naming Conventions

Use Bash for scripts and Markdown for skills and docs. Shell scripts should start with `#!/bin/bash`, prefer `set -euo pipefail` for executable workflows, quote variable expansions, and keep portable macOS/Linux behavior where possible. Use two-space indentation in shell functions and JSON. Name scripts with lowercase kebab-case, such as `cache-read-comment.sh`; name skills with lowercase kebab-case directories.

## Testing Guidelines

No formal test suite is present. Validate changes with targeted command checks: run `bash -n` for edited scripts, `jq empty` for edited JSON, and execute the specific script path you changed when practical. For skill changes, review the trigger phrases and required tools in the edited `SKILL.md`, then verify any referenced scripts or files exist.

## Commit & Pull Request Guidelines

Recent history follows Conventional Commits, for example `fix(resolver): add missing allowed-tools` and `feat(cache): eliminate temp files with stdin pipe architecture`. Use `feat`, `fix`, `chore`, or `docs`, with an optional scope. PRs should include a concise summary, validation commands run, linked issues when applicable, and screenshots or pasted command output only when they clarify behavior. For release PRs, update `CHANGELOG.md` and keep `.claude-plugin/plugin.json` aligned with `.claude-plugin/marketplace.json`.

## Security & Configuration Tips

Do not commit `.pr-review-cache/`, tokens, or local Claude/GitHub credentials. Treat GitHub comment payloads as external input and prefer `jq` or structured parsing over ad hoc text edits.
