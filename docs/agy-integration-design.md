# Antigravity (`agy`) Integration Design

**Status:** Implemented
**Target repo:** `marxbiotech/pr-review-toolkit`
**Primary goals:**

1. Let Antigravity (`agy`) install and run the six-agent PR review workflow (`agy-review-pass`, `pr-review-and-document`, `gemini-review-integrator`, `pr-review-resolver`, `agy-fix-worker`) with the six packaged review agents.
2. Support both **GitHub Release Marketplace** installation (`agy plugin install pr-review-toolkit@marxbiotech`) and **local packaged directory** installation (`agy plugin install ./plugins/pr-review-toolkit`).
3. Keep the existing `.pr-review-cache/pr-{PR_NUMBER}.json` and `<!-- pr-review-metadata ... -->` GitHub PR comment as the single source of truth across Claude, Gemini, Codex, Grok, and Antigravity (`AGY`).
4. Ensure `agy plugin validate --strict ./plugins/pr-review-toolkit` passes with zero errors and zero warnings.

---

## 1. Plugin & Marketplace Layout

Antigravity discovers native plugins via `.antigravity-plugin/plugin.json` inside the plugin root and auto-scans `<plugin-root>/skills/*/SKILL.md` and `<plugin-root>/agents/*.md`.

```text
.antigravity-plugin/
└── marketplace.json                       # Tracked AGY marketplace template (published with SHA-256 on GitHub Release)
plugins/
└── pr-review-toolkit/
    ├── .antigravity-plugin/
    │   └── plugin.json                    # Antigravity plugin manifest
    ├── .codex-plugin/
    │   └── plugin.json                    # Codex plugin manifest
    ├── .grok-plugin/
    │   └── plugin.json                    # Grok plugin manifest
    ├── agents/                            # Six read-only review agents shared by AGY and Grok
    │   ├── code-reviewer.md
    │   ├── code-simplifier.md
    │   ├── comment-analyzer.md
    │   ├── pr-test-analyzer.md
    │   ├── silent-failure-hunter.md
    │   └── type-design-analyzer.md
    ├── skills/                            # Packaged skills scanned by AGY and Grok
    │   ├── agy-review-pass/
    │   │   └── SKILL.md
    │   ├── agy-fix-worker/
    │   │   └── SKILL.md
    │   ├── gemini-review-integrator/
    │   │   └── SKILL.md
    │   ├── grok-review-pass/
    │   │   └── SKILL.md
    │   ├── grok-fix-worker/
    │   │   └── SKILL.md
    │   ├── pr-review-and-document/
    │   │   └── SKILL.md
    │   └── pr-review-resolver/
    │       ├── SKILL.md
    │       └── references/
    │           └── interaction-example.md
    └── scripts/                           # Byte-identical packaged copy of root scripts/
```

### How Antigravity Marketplace Works

Unlike Claude Code or Grok (which support relative paths in `marketplace.json`), Antigravity's marketplace loader (`jetski/language_server/marketplace`) requires every plugin entry's `source` to be an HTTPS `.zip` archive with a 64-character hex `sha256` digest:

```json
{
  "name": "marxbiotech",
  "plugins": [
    {
      "name": "pr-review-toolkit",
      "version": "4.0.0",
      "source": {
        "type": "archive",
        "url": "https://github.com/marxbiotech/pr-review-toolkit/releases/download/v4.0.0/pr-review-toolkit-agy.zip",
        "sha256": "<64-char-sha256>"
      }
    }
  ]
}
```

During `.github/workflows/release.yml`, CI automatically:
1. Zips `plugins/pr-review-toolkit/` into `pr-review-toolkit-agy.zip`.
2. Computes the SHA-256 digest of `pr-review-toolkit-agy.zip`.
3. Generates `marketplace.json` from `.antigravity-plugin/marketplace.json` with the release version, download URL, and SHA-256.
4. Uploads both `pr-review-toolkit-agy.zip` and `marketplace.json` as GitHub Release assets.

Users register `https://github.com/marxbiotech/pr-review-toolkit/releases/latest/download/marketplace.json` in `~/.gemini/config/config.json` under `agy-plugin-marketplaces` and install via `agy plugin install pr-review-toolkit@marxbiotech`.

---

## 2. Toolkit Root Resolution

Every skill under `plugins/pr-review-toolkit/skills/` resolves `PR_REVIEW_TOOLKIT_ROOT` in this order:

1. `AGY_PLUGIN_ROOT` when set by the Antigravity plugin runtime.
2. `GROK_PLUGIN_ROOT` when set by the Grok plugin runtime.
3. `PR_REVIEW_TOOLKIT_ROOT` when set in the environment.
4. Two levels up from `SKILL_PATH` (`<root>/skills/<skill-name>/SKILL.md`), verifying `<root>/scripts/cache-write-comment.sh` and at least one of `<root>/.antigravity-plugin/plugin.json` or `<root>/.grok-plugin/plugin.json`.

---

## 3. Shared Comment & Metadata Schema (`1.1`)

Antigravity (`agy`) is a first-class review source in schema `1.1`:

- **Issue Title Prefix**: `[AGY]` (e.g. `<summary><b>1. ⚠️ [AGY] Issue title</b></summary>`)
- **Source Line**: `**Source:** AGY`
- **Finding ID Grammar**: `agy:<file>:<symbol-or-nearest-heading>:<diagnostic-kind>:<snippet-hash>`
- **Reviewer Sources Line**: Rendered in fixed order `Claude, Gemini, Codex, Grok, AGY`
- **Metadata Block**:
  ```json
  "review_sources": {
    "agy": {
      "last_reviewed_head": "HEAD_SHA",
      "last_reviewed_at": "YYYY-MM-DDTHH:MM:SSZ",
      "posted_finding_ids": ["agy:path:symbol:kind:hash"],
      "agents_run": [
        "code-reviewer",
        "code-simplifier",
        "silent-failure-hunter",
        "type-design-analyzer",
        "pr-test-analyzer",
        "comment-analyzer"
      ]
    }
  }
  ```

---

## 4. Antigravity Subagent & Tool Mapping

| Role | Skill | Antigravity Tool Usage |
| :--- | :--- | :--- |
| Six-agent review producer | `agy-review-pass` | Calls `invoke_subagent` 6 times in parallel (using registered plugin agents or `TypeName: "research"` with `${PR_REVIEW_TOOLKIT_ROOT}/agents/<agent>.md` prompts), then waits for reactive wakeup. |
| Canonical comment publisher | `pr-review-and-document` | Runs `agy-review-pass`, validates the 6-agent bundle, upgrades metadata via `review-metadata-upgrade.sh`, and writes via `cache-write-comment.sh`. |
| Gemini review integrator | `gemini-review-integrator` | Runs `fetch-gemini-comments.sh`, deduplicates against `review_sources.gemini.consumed_comment_ids`, and merges `[Gemini]` findings. |
| Interactive zh-TW resolver | `pr-review-resolver` | Presents each unresolved issue in Traditional Chinese, uses `ask_question` for user decision, dispatches `agy-fix-worker` via `invoke_subagent` (`TypeName: "self"`), validates owned file scope via `check-fix-worker-scope.sh` and `parse-validation-entry.sh`, and updates the comment. |
| Bounded single-issue fixer | `agy-fix-worker` | Edits only `OWNED_FILES`, runs targeted validation, and reports `Validation:` + `Status:` without touching `.pr-review-cache` or PR comments. |
