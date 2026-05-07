# Releasing Guide

This document describes how to release new versions of the pr-review-toolkit plugin.

## Version Fields

| File | Field | Purpose |
|------|-------|---------|
| `.claude-plugin/plugin.json` | `version` | **Plugin version (authoritative source)** |
| `.claude-plugin/marketplace.json` | `plugins[0].version` | Plugin version (must match plugin.json) |
| `.claude-plugin/marketplace.json` | `metadata.version` | Marketplace format version (not plugin version, keep at 1.0.0) |
| `plugins/pr-review-toolkit/.codex-plugin/plugin.json` | `version` | Codex plugin version (must match plugin.json) |
| `.agents/plugins/marketplace.json` | `plugins[0].source.path` | Repo-scoped Codex marketplace entry (keep as `./plugins/pr-review-toolkit`) |

> **Important:** `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` plugins[0].version, and `plugins/pr-review-toolkit/.codex-plugin/plugin.json` must always use the same plugin version.

> **Plugin naming:** The Claude plugin name `pr-workflow` is preserved for marketplace-install backwards compatibility (existing users have it pinned by name); the Codex plugin name `pr-review-toolkit` aligns with the repo name and is the canonical project identifier going forward. Both ecosystems intentionally use different `name` values — the cross-manifest invariant the release flow enforces is `.version` parity, not `.name` parity.

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
- Update version in `plugin.json`, `marketplace.json`, and `plugins/pr-review-toolkit/.codex-plugin/plugin.json`
- Update `CHANGELOG.md`
- Commit and push to main
- Trigger the release workflow automatically

### Method B: Manual Release

Use Method A when possible. If you must release manually, make the change in a PR unless you are deliberately performing an emergency direct push.

1. Update versions in all plugin manifests:
   ```bash
   # Edit .claude-plugin/plugin.json
   # Edit .claude-plugin/marketplace.json (plugins[0].version only)
   # Edit plugins/pr-review-toolkit/.codex-plugin/plugin.json
   ```

2. Update `CHANGELOG.md`:
   - Add a new section under `## [Unreleased]`
   - Follow [Keep a Changelog](https://keepachangelog.com/) format

3. Verify all three versions match before committing:
   ```bash
   set -euo pipefail
   A=$(jq -e -r '.version' .claude-plugin/plugin.json) || {
     echo "Failed to read .version from .claude-plugin/plugin.json"; exit 1; }
   B=$(jq -e -r '.plugins[0].version' .claude-plugin/marketplace.json) || {
     echo "Failed to read .plugins[0].version from .claude-plugin/marketplace.json"; exit 1; }
   C=$(jq -e -r '.version' plugins/pr-review-toolkit/.codex-plugin/plugin.json) || {
     echo "Failed to read .version from plugins/pr-review-toolkit/.codex-plugin/plugin.json"; exit 1; }
   if [ "$A" != "$B" ] || [ "$A" != "$C" ]; then
     echo "Version mismatch: A=$A B=$B C=$C"
     echo "Restore parity before committing — partial bumps trigger release.yml without CI gating."
     exit 1
   fi
   echo "✓ All three at $A"
   ```

   **Run this command before `git commit`.** If it fails, fix the missing manifest and re-run. CI on main (`validate.yml` push trigger) will also catch drift, but local verification is faster and prevents a known-bad commit from reaching origin.

4. Commit and push:
   ```bash
   git add .claude-plugin/plugin.json .claude-plugin/marketplace.json plugins/pr-review-toolkit/.codex-plugin/plugin.json CHANGELOG.md
   git commit -m "chore: bump version to X.Y.Z"
   git push
   ```

5. The release workflow will automatically:
   - Create a git tag
   - Create a GitHub Release with auto-generated notes

## CI/CD Workflows

### validate.yml (PR Validation)

Runs on every PR to main:
- Validates JSON syntax
- Checks semver format
- Ensures version consistency between Claude and Codex plugin files
- Verifies required files exist
- Verifies Codex marketplace metadata, skill frontmatter, and toolkit-root contract

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

Update all plugin manifests to have matching versions:
- `.claude-plugin/plugin.json` → `version`
- `.claude-plugin/marketplace.json` → `plugins[0].version`
- `plugins/pr-review-toolkit/.codex-plugin/plugin.json` → `version`

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
4. Verify the Codex manifest and skill path:
   ```bash
   jq empty .agents/plugins/marketplace.json plugins/pr-review-toolkit/.codex-plugin/plugin.json
   test "$(jq -r '.plugins[0].source.path' .agents/plugins/marketplace.json)" = "./plugins/pr-review-toolkit"
   test "$(jq -r '.skills' plugins/pr-review-toolkit/.codex-plugin/plugin.json)" = "./codex/skills/"
   ```
