# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [5.0.0] - 2026-10-20

Antigravity (`agy`) is now a first-class review producer alongside Claude, Gemini, Codex, and Grok. This major release ships native Antigravity plugin and GitHub Release marketplace packaging, Antigravity skills (`agy-review-pass`, `agy-fix-worker`, `gemini-review-integrator`, `pr-review-and-document`, `pr-review-resolver`), and additive `review_sources.agy` metadata so Claude, Gemini, Codex, Grok, and Antigravity can share the same canonical PR comment.

### Added

- Antigravity (`agy`) plugin packaging: `plugins/pr-review-toolkit/.antigravity-plugin/plugin.json` plus `.antigravity-plugin/marketplace.json`, with automated `pr-review-toolkit-agy.zip` and `marketplace.json` (with SHA-256) asset generation in `release.yml`
- `agy-review-pass` skill: launches six parallel read-only review subagents in Antigravity and returns a deduplicated finding bundle with `agy:` finding IDs
- `agy-fix-worker` skill: resolver-managed, bounded per-issue fix executor for Antigravity — explicitly forbidden from touching review state
- Packaged `gemini-review-integrator` skill under `plugins/pr-review-toolkit/skills/` for integrating Gemini Code Assist inline comments in Antigravity and Grok
- `review_sources.agy` in comment metadata schema 1.1, preserved and normalized by `review-metadata-upgrade.sh`
- Antigravity integration design doc under `docs/agy-integration-design.md`

### Changed

- Packaged `pr-review-and-document` and `pr-review-resolver` skills and the six review agents under `plugins/pr-review-toolkit/` now support both Antigravity (`AGY_PLUGIN_ROOT`, `[AGY]`, `agy:`) and Grok (`GROK_PLUGIN_ROOT`, `[Grok]`, `grok:`)
- Claude, Codex, and Grok skills now preserve `[AGY]` findings and `review_sources.agy`
- `Reviewer Sources` display order is `Claude, Gemini, Codex, Grok, AGY`
- CI (`validate.yml`, `bump-version.yml`, `release.yml`) enforces version parity across all seven plugin and marketplace manifests and locks the `agy-fix-worker` resolver-managed contract
- Major version bump (5.0.0) marking the Antigravity (`agy`) full-port milestone

## [4.0.0] - 2026-09-15

Grok is now a first-class review producer alongside Claude and Codex. This major release ships Grok marketplace packaging, Grok skills, and additive `review_sources.grok` metadata so Claude/Codex/Grok can share the same canonical PR comment.

### Added

- Grok plugin packaging: `.grok-plugin/marketplace.json` plus `plugins/pr-review-toolkit/.grok-plugin/plugin.json`, with Grok skills under `plugins/pr-review-toolkit/skills/` and six read-only review agents under `plugins/pr-review-toolkit/agents/`
- `grok-review-pass` skill: launches parallel read-only review subagents and returns a deduplicated finding bundle
- `pr-review-and-document` Grok skill: publishes the bundle through the shared `.pr-review-cache/pr-#.json` contract
- `pr-review-resolver` Grok skill: discusses unresolved findings one by one in Traditional Chinese and coordinates bounded fix work
- `grok-fix-worker` Grok skill: resolver-managed, bounded per-issue fix executor — explicitly forbidden from touching review state
- `review_sources.grok` in comment metadata schema 1.1, preserved by `review-metadata-upgrade.sh`
- Grok integration design doc under `docs/grok-integration-design.md`

### Changed

- Claude and Codex skills now preserve `[Grok]` findings and `review_sources.grok`
- `Reviewer Sources` display order is `Claude, Gemini, Codex, Grok`
- CI, bump-version, and release workflows keep Grok marketplace and plugin manifests in version parity with Claude and Codex
- Major version bump (4.0.0) marking the Grok full-port milestone

## [3.0.0-rc.1] - 2026-06-01

Release candidate for v3.0.0. The Codex side of the toolkit reaches feature parity with the Claude side: parallel review producer, canonical comment writer, Gemini integrator, interactive resolver, and resolver-managed bounded fix worker.

### Added

- `codex-review-pass` skill: launches parallel read-only review subagents and returns a deduplicated finding bundle in bootstrap and append modes
- `pr-review-and-document` Codex skill: publishes the bundle through the shared `.pr-review-cache/pr-#.json` contract
- `gemini-review-integrator` Codex skill: merges Gemini Code Assist comments into the canonical PR review comment
- `pr-review-resolver` Codex skill: discusses unresolved findings one by one, coordinates user decisions, and owns review-state updates
- `codex-fix-worker` Codex skill: resolver-managed, bounded per-issue fix executor — explicitly forbidden from touching review state
- Structural CI lint that rejects PR-round identifiers (`R1`, `round-2`, etc.) leaking into source/skill files, with a self-exclusion test suite
- Composite GitHub Action `check-script-parity` shared between `validate.yml` and `release.yml`
- Helper extractions with dedicated test suites: `disambiguate-stale-source`, `extract-content-hash`, `parse-validation-entry`, `review-metadata-upgrade`
- Codex integration design docs under `docs/`

### Changed

- `release.yml` and `validate.yml` now enforce script-tree parity, Codex skill frontmatter, and `${PR_REVIEW_TOOLKIT_ROOT}/scripts/*` reference resolution against both authoritative and packaged trees
- Shell test suites run against `scripts/` and `plugins/pr-review-toolkit/scripts/` so the packaging contract is exercised end-to-end
- Major version bump (3.0.0-rc.1) marking the Codex full-port milestone

## [2.0.2] - 2026-05-11

### Changed

- Version bump (patch)


### Fixed

- Package the shared helper scripts under `plugins/pr-review-toolkit/scripts/` so installed Codex skills can execute their required `PR_REVIEW_TOOLKIT_ROOT/scripts/*` helpers without depending on a separate Claude plugin bundle. Previously, Codex installs aborted at preflight with `Missing executable helper: …/scripts/<helper>.sh` because the packaged plugin shipped only manifests and skill files. Fixes #14.

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

[Unreleased]: https://github.com/marxbiotech/pr-review-toolkit/compare/v5.0.0...HEAD
[5.0.0]: https://github.com/marxbiotech/pr-review-toolkit/compare/v4.0.0...v5.0.0
[4.0.0]: https://github.com/marxbiotech/pr-review-toolkit/compare/v3.0.0-rc.1...v4.0.0
[3.0.0-rc.1]: https://github.com/marxbiotech/pr-review-toolkit/compare/v2.0.2...v3.0.0-rc.1
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
