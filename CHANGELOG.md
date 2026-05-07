# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
## [2.0.1] - 2026-05-07

### Changed

- Version bump (patch)


### Fixed

- Codex marketplace entry no longer skipped by `/plugins`. The marketplace `source.path` was `./` (the repo root), which Codex normalized to an empty local plugin path and rejected with `local plugin source path must not be empty`. The Codex plugin is now packaged under `plugins/pr-review-toolkit/` (manifest at `plugins/pr-review-toolkit/.codex-plugin/plugin.json`, skills at `plugins/pr-review-toolkit/codex/skills/`), and `.agents/plugins/marketplace.json` points at `./plugins/pr-review-toolkit` so Codex resolves a concrete plugin folder. The Claude marketplace (`.claude-plugin/marketplace.json` with `source: "./"`) is unchanged. Fixes #11.

## [2.0.0] - 2026-05-07

### Added

- Add Codex skill scaffolding for `codex-review-pass` and `codex-fix-worker`
- Add Codex plugin manifest at `.codex-plugin/plugin.json`
- Add repo-scoped Codex marketplace metadata at `.agents/plugins/marketplace.json`
- Add compare-and-swap protection to `cache-write-comment.sh --stdin` via `--expected-content-hash`
- Add shared `review-metadata-upgrade.sh` helper with fixtures and tests for metadata migration
- Add shared `review-metadata-replace.sh` helper with preservation tests for metadata block updates
- Document Codex integration design and Claude review responses

### Changed

- Update PR review skills to preserve multi-source metadata and use cache hash checks when writing
- Extend validation and release workflows to check Codex marketplace metadata, plugin packaging, skill frontmatter, and cross-manifest versions
- Major version bump (2.0.0)

### Breaking Changes

This release is major due to:

- **Comment metadata schema 1.0 → 1.1.** External consumers reading the `<!-- pr-review-metadata -->` block directly must migrate to the new `review_sources.{claude,gemini,codex}` shape. Legacy fields (`agents_run`, `gemini_integrated_ids`, `gemini_integration_date`) are still populated during the Phase-2 compatibility window; they will be removed in a future release.
- **CAS contract enforced for cache writes.** `cache-write-comment.sh` now validates `--expected-content-hash` strictly (must be `sha256:` followed by 64 hex characters; empty rejected). Callers that previously omitted the flag still work, but anyone passing a malformed hash now fails with exit 2 instead of silently skipping protection.
- **Multi-block content rejected at write time.** `cache-write-comment.sh` now refuses content with 0 or >1 `<!-- pr-review-metadata` markers, exiting 2 with an explicit error.

## [1.4.2] - 2026-02-08

### Changed

- Version bump (patch)

## [1.4.1] - 2026-02-06

### Changed

- Version bump (patch)


## [1.4.0] - 2026-02-06

### Changed

- Version bump (minor)


## [1.3.1] - 2026-02-05

### Changed

- Version bump (patch)


## [1.3.0] - 2026-02-05

### Changed

- Version bump (minor)


## [1.2.2] - 2026-02-03

### Changed

- Use `arc-light` self-hosted runner for bump-version workflow

## [1.2.1] - 2026-02-01

### Fixed

- Update SKILL.md `name` frontmatter fields to comply with Agent Skills specification (lowercase, hyphenated, matching directory names)

## [1.2.0] - 2026-01-29

### Fixed

- Move `deploy-pr` command from `.claude/commands/` to `commands/` for plugin discovery
- Add YAML frontmatter (description, allowed-tools) and use `${CLAUDE_PLUGIN_ROOT}` for script path

### Changed

- Rename plugin from `pr-review-toolkit` to `pr-workflow` to avoid namespace collision with official plugins

## [1.1.0] - 2025-01-26

### Added

- `/deploy-pr` command for environment deployment

## [1.0.0] - 2025-01-26

### Added

- Initial release
- `pr-review-and-document` skill: Execute comprehensive PR review using opus model and post structured results as a PR comment
- `gemini-review-integrator` skill: Integrate Gemini Code Assist suggestions into the existing PR review comment
- `pr-review-resolver` skill: Interactively resolve PR review issues one by one (繁體中文)
- Shared scripts for PR comment management:
  - `find-review-comment.sh`
  - `upsert-review-comment.sh`
  - `fetch-gemini-comments.sh`
- Marketplace configuration for `marxbiotech/pr-review-toolkit`

[Unreleased]: https://github.com/marxbiotech/pr-review-toolkit/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/marxbiotech/pr-review-toolkit/compare/v1.4.2...v2.0.0
[1.4.2]: https://github.com/marxbiotech/pr-review-toolkit/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/marxbiotech/pr-review-toolkit/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/marxbiotech/pr-review-toolkit/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/marxbiotech/pr-review-toolkit/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/marxbiotech/pr-review-toolkit/compare/v1.2.2...v1.3.0
[1.2.2]: https://github.com/marxbiotech/pr-review-toolkit/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/marxbiotech/pr-review-toolkit/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/marxbiotech/pr-review-toolkit/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/marxbiotech/pr-review-toolkit/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/marxbiotech/pr-review-toolkit/releases/tag/v1.0.0
