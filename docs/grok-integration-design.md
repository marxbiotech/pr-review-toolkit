# Grok Integration Design

> 目標：讓同一個 `pr-review-toolkit` repository 支援 Claude Code、Codex 與 Grok，並繼續以 `.pr-review-cache/pr-#.json` 作為唯一的 PR review 狀態 contract。

Grok 包裝沿用 Codex 的責任切分與 cache/comment helpers。共享 contract 以 [`docs/codex-integration-design.md`](codex-integration-design.md) 為準；本文只記錄 Grok runtime 差異。

## Packaging

```text
.grok-plugin/marketplace.json
  → source.path = ./plugins/pr-review-toolkit

plugins/pr-review-toolkit/
  .grok-plugin/plugin.json
  skills/                 Grok skills (default discovery)
  agents/                 six read-only review agents
  scripts/                packaged helpers (byte-identical to scripts/)
  .codex-plugin/          Codex packaging (unchanged)
  codex/skills/           Codex skills (unchanged)
```

Do not install the repository root as a Grok plugin. The root `.claude-plugin/` manifest is the Claude plugin (`pr-workflow`) and would load Claude skills. Add this repo as a Grok marketplace and install `pr-review-toolkit`:

```bash
grok plugin marketplace add marxbiotech/pr-review-toolkit
grok plugin install pr-review-toolkit --trust
```

Local source:

```bash
grok plugin marketplace add .
grok plugin install pr-review-toolkit --trust
```

## Skills

| Skill | Role |
|---|---|
| `grok-review-pass` | Read-only producer. Spawns six review agents and returns a bundle. |
| `pr-review-and-document` | Publisher. Writes the bundle through `cache-write-comment.sh`. |
| `pr-review-resolver` | Interactive Traditional Chinese resolver. Owns status updates. |
| `grok-fix-worker` | Resolver-managed fixer. Edits owned files only. Never writes review state. |

`grok-review-pass` must run in the parent Grok session. Grok subagents cannot spawn children.

## Environment

Resolve the packaged plugin root in this order:

1. `GROK_PLUGIN_ROOT` (Grok plugin runtime). Assign it to `PR_REVIEW_TOOLKIT_ROOT`.
2. `PR_REVIEW_TOOLKIT_ROOT` when already set (source installs; same variable as Codex).
3. Derive from the skill path: this SKILL.md lives at `<root>/skills/<skill-name>/SKILL.md`, so `<root>` is two levels up. Sentinels: `<root>/.grok-plugin/plugin.json` and `<root>/scripts/cache-write-comment.sh`.
4. Stop and ask for the root.

Canonicalize before use. Do not use `${CLAUDE_PLUGIN_ROOT}`.

## Metadata

Comment metadata stays schema `1.1`. `review_sources.grok` is additive:

```json
"grok": {
  "last_reviewed_head": "abc123",
  "last_reviewed_at": "2026-09-15T00:00:00Z",
  "posted_finding_ids": ["grok:src/foo.ts:symbol:error-handling:abcd1234"],
  "agents_run": ["code-reviewer", "code-simplifier", "silent-failure-hunter", "type-design-analyzer", "pr-test-analyzer", "comment-analyzer"]
}
```

Finding IDs use the `grok:` prefix. Canonical issue titles use `[Grok]`.

`Reviewer Sources` display order is `Claude, Gemini, Codex, Grok`. Include Grok when `review_sources.grok.last_reviewed_at != null`.

`review-metadata-upgrade.sh` preserves `review_sources.grok` (and `review_sources.codex.agents_run`) so a Claude/Codex/Gemini writer cannot wipe Grok state.

## Agents

The six review agents live at `plugins/pr-review-toolkit/agents/` and spawn as `pr-review-toolkit:<name>` with `permission_mode: plan`. If a plugin agent type is unavailable, `grok-review-pass` falls back to the built-in `explore` type and inlines the agent body.
