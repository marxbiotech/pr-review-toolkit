# Releasing Guide

This document describes how to release new versions of the pr-review-toolkit plugin.

## Version Fields

| File | Field | Purpose |
|------|-------|---------|
| `.claude-plugin/plugin.json` | `version` | **Plugin version (authoritative source)** |
| `.claude-plugin/marketplace.json` | `plugins[0].version` | Plugin version (must match plugin.json) |
| `.claude-plugin/marketplace.json` | `metadata.version` | Marketplace format version (not plugin version, keep at 1.0.0) |

> **Important:** `plugin.json` version and `marketplace.json` plugins[0].version must always be identical.

## Semantic Versioning

This project follows [Semantic Versioning](https://semver.org/):

- **MAJOR** (x.0.0): Breaking changes
  - Removing or renaming skills
  - Changing script interfaces
  - Breaking changes to command behavior

- **MINOR** (0.x.0): New features (backwards compatible)
  - Adding new skills
  - Adding new scripts
  - New optional parameters

- **PATCH** (0.0.x): Bug fixes (backwards compatible)
  - Bug fixes
  - Documentation improvements
  - Performance improvements

## Release Methods

### Method A: GitHub Actions (Recommended)

1. Go to **Actions** > **Bump Version** > **Run workflow**
2. Select the bump type (patch/minor/major)
3. Click **Run workflow**

The workflow will:
- Update version in `plugin.json` and `marketplace.json`
- Update `CHANGELOG.md`
- Commit and push to main
- Trigger the release workflow automatically

### Method B: Manual Release

1. Update versions in both files:
   ```bash
   # Edit .claude-plugin/plugin.json
   # Edit .claude-plugin/marketplace.json (plugins[0].version only)
   ```

2. Update `CHANGELOG.md`:
   - Add a new section under `## [Unreleased]`
   - Follow [Keep a Changelog](https://keepachangelog.com/) format

3. Commit and push:
   ```bash
   git add .claude-plugin/plugin.json .claude-plugin/marketplace.json CHANGELOG.md
   git commit -m "chore: bump version to X.Y.Z"
   git push
   ```

4. The release workflow will automatically:
   - Create a git tag
   - Create a GitHub Release with auto-generated notes

## CI/CD Workflows

### validate.yml (PR Validation)

Runs on every PR to main:
- Validates JSON syntax
- Checks semver format
- Ensures version consistency between files
- Verifies required files exist

### release.yml (Auto Release)

Runs when `plugin.json` changes on main:
- Checks if tag already exists
- Generates changelog from commits
- Creates git tag
- Creates GitHub Release

### bump-version.yml (Manual Trigger)

Manually triggered workflow:
- Bumps version based on selected type
- Updates all version files
- Commits directly to main

## Troubleshooting

### Release not created after merge

1. Check if the tag already exists:
   ```bash
   git tag -l "v*"
   ```

2. Check Actions tab for workflow run status

3. Ensure `plugin.json` was modified in the merge commit

### Version mismatch error in PR

Update both files to have matching versions:
- `.claude-plugin/plugin.json` → `version`
- `.claude-plugin/marketplace.json` → `plugins[0].version`

### Manual tag creation

If you need to create a tag manually:
```bash
git tag -a v1.2.3 -m "Release v1.2.3"
git push origin v1.2.3
```

Then create the GitHub Release manually via the web UI.

## Post-Release Verification

After a release:

1. Verify the GitHub Release was created
2. Test installation (in Claude Code):
   ```
   /plugin marketplace add marxbiotech/pr-review-toolkit
   /plugin install pr-review-toolkit
   ```
3. Verify the plugin loads correctly in Claude Code
