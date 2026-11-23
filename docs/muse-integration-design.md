# Muse Integration Design

> 目標：讓同一個 `pr-review-toolkit` repository 支援 Claude Code、Codex、Grok 與 Muse，並繼續以 `.pr-review-cache/pr-#.json` 作為唯一的 PR review 狀態 contract。

Muse 包裝沿用 Codex 的責任切分與 cache/comment helpers。共享 contract 以 [`docs/codex-integration-design.md`](codex-integration-design.md) 為準；本文只記錄 Muse runtime 差異。

## Packaging

```text
.agents/plugins/marketplace.json  shared Codex/Muse marketplace catalog
  → plugins[0].source.path = ./plugins/pr-review-toolkit

plugins/pr-review-toolkit/
  .muse-plugin/plugin.json        Muse native manifest (schemaVersion 1)
  muse/skills/                    Muse skills
  muse/skills/muse-review-pass/references/agents/
                                  six read-only review agent prompts
  scripts/                        packaged helpers (byte-identical to scripts/)
  .codex-plugin/                  Codex packaging (unchanged)
  codex/skills/                   Codex skills (unchanged)
  .grok-plugin/                   Grok packaging (unchanged)
  skills/                         Grok skills (unchanged)
  agents/                         Grok review agents (unchanged)
```

Muse 的 marketplace resolver 依序探測 `marketplace.json`、`.agents/plugins/marketplace.json`、`.claude-plugin/marketplace.json`。本 repo 沿用既有的 `.agents/plugins/marketplace.json`：它同時是 Codex catalog 與 Muse 探測路徑之一，`pr-review-toolkit` entry 指向同一個 packaged 目錄。不新增 repo-root `marketplace.json`，因為那是 Muse native catalog 格式，要求每個 plugin 宣告 `integrity.digest`（套件摘要），不利人工維護。

同一個 packaged plugin 目錄同時帶 `.codex-plugin/`、`.grok-plugin/`、`.muse-plugin/` 三份 manifest；每個 runtime 只讀自己的 manifest。Muse validator 在同目錄有多份 manifest 時優先選 `.muse-plugin/plugin.json`（native），並對被忽略的 `.codex-plugin/plugin.json` 發出 `multiple-manifests` warning — 這是多 harness 共存的預期行為，不是錯誤。

安裝（GitHub public repo）：

```bash
muse plugins marketplace add marxbiotech https://github.com/marxbiotech/pr-review-toolkit
muse plugins install pr-review-toolkit@marxbiotech
```

本地 source：

```bash
muse plugins marketplace add marxbiotech .
muse plugins install pr-review-toolkit@marxbiotech
```

驗證（不安裝）：

```bash
muse plugins validate plugins/pr-review-toolkit
muse skills validate plugins/pr-review-toolkit/muse/skills/pr-review-and-document
```

## Skills

| Skill | Role |
|---|---|
| `muse-review-pass` | Read-only producer. Spawns six review subagents and returns a bundle. |
| `pr-review-and-document` | Publisher. Writes the bundle through `cache-write-comment.sh`. |
| `gemini-review-integrator` | Integrator. Merges Gemini Code Assist feedback into the canonical comment. |
| `pr-review-resolver` | Interactive Traditional Chinese resolver. Owns status updates. |
| `muse-fix-worker` | Resolver-managed fixer. Edits owned files only. Never writes review state. |

## Muse Runtime Mapping

Muse skills 把 harness 原語寫成 Muse 的對應物，不沿用 Claude Code 的 `Task` / `AskUserQuestion`、Codex 的抽象 worker 命名，或 Grok 的 `spawn_subagent` / `ask_user_question`：

| 需求 | Muse 對應 |
|---|---|
| 六代理 review | 以 session 的 subagent 工具平行 spawn 六個 general-purpose 子代理，背景執行、共用 workspace（不做 worktree isolation），prompt 內載入 `references/agents/<agent>.md` 並要求只回 findings |
| 逐項決策提問 | 優先用 structured question 工具；不可用時以編號選項呈現並等待使用者回覆 |
| Bounded fix | Spawn 背景子代理，prompt 載入 `muse/skills/muse-fix-worker/SKILL.md` 全文，加上 PR 編號、issue、owned files 與使用者決策 |
| 收集子代理結果 | 等待子代理完成並讀取其最終報告；以 `Status:` 行與 `parse-validation-entry.sh` 交叉驗證，不以檔案清單推斷成功 |

## Environment

Resolve the packaged plugin root in this order:

1. `PR_REVIEW_TOOLKIT_ROOT` when set (supported path, same variable as Codex/Grok source installs).
2. `MUSE_PLUGIN_ROOT` when set (Muse plugin runtime) and `PR_REVIEW_TOOLKIT_ROOT` is unset.
3. Derive from the skill path: Muse SKILL.md lives at `<root>/muse/skills/<skill-name>/SKILL.md`, so `<root>` is exactly three levels up. Sentinels: `<root>/.muse-plugin/plugin.json` and `<root>/scripts/cache-write-comment.sh`.
4. Stop and ask for `PR_REVIEW_TOOLKIT_ROOT`.

Canonicalize before use. Do not use `${CLAUDE_PLUGIN_ROOT}`.

## Metadata

Comment metadata stays schema `1.1`. `review_sources.muse` is additive and mirrors the Codex/Grok shape:

```json
"muse": {
  "last_reviewed_head": "abc123",
  "last_reviewed_at": "2026-11-23T00:00:00Z",
  "posted_finding_ids": ["muse:src/foo.ts:symbol:error-handling:abcd1234"],
  "agents_run": ["code-reviewer", "code-simplifier", "silent-failure-hunter", "type-design-analyzer", "pr-test-analyzer", "comment-analyzer"]
}
```

Finding IDs use the `muse:` prefix. Canonical issue titles use `[Muse]`.

`Reviewer Sources` display order is `Claude, Gemini, Codex, Grok, AGY, Muse`. Include Muse when `review_sources.muse.last_reviewed_at != null`.

`review-metadata-upgrade.sh` preserves `review_sources.muse` (and every other source) so any harness writer cannot wipe Muse state. The upgrade is covered by `tests/review-metadata-upgrade-test.sh` (legacy defaults, bootstrap defaults, and Muse preservation across re-upgrade).
