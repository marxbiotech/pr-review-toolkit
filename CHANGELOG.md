# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/marxbiotech/pr-review-toolkit/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/marxbiotech/pr-review-toolkit/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/marxbiotech/pr-review-toolkit/releases/tag/v1.0.0
