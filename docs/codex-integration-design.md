# Codex Integration Design

> 目標：讓同一個 `pr-review-toolkit` repository 同時支援 Claude Code plugin 與 Codex skills，並以 `.pr-review-cache/pr-#.json` 作為 Claude、Codex、Gemini 與 dev agent 之間唯一的 PR review 狀態 contract。

## 背景與設計目標

目前 workflow 以 Claude Code marketplace plugin 為主：

```text
pr-review-and-document
→ gemini-review-integrator
→ pr-review-resolver
→ repeat review / resolve loop
```

新的實際使用情境是：dev agent 會自行操作 Claude Code 與 Codex 兩個 tool 完成 PR review 與修復，不需要透過 Claude Code 間接呼叫 Codex。因此 Codex 應該有自己的 skills：

```text
codex-review-pass
codex-fix-worker
```

兩個 Codex skills 必須使用現有 cache/comment contract，不建立額外狀態檔，避免 workflow 分裂。

## Single Source of Truth

唯一允許的 PR review 狀態檔是：

```text
.pr-review-cache/pr-#.json
```

這個檔案有兩層 schema，必須明確區分：

- **Cache envelope schema**：`.pr-review-cache/pr-#.json` 外層結構，由 `scripts/cache-*.sh` 擁有，維持 `schema_version: "1.0"`。
- **Comment metadata schema**：`content` 內 `<!-- pr-review-metadata ... -->` 的 JSON，由 skills 擁有，會從 `1.0` 升級到 `1.1`。

目前 cache envelope 結構：

```json
{
  "schema_version": "1.0",
  "pr_number": 123,
  "source_comment_id": 1234567890,
  "cached_at": "2026-04-30T12:00:00Z",
  "pr_state": "OPEN",
  "branch": "feature-branch",
  "base": "main",
  "content": "<!-- pr-review-metadata ... -->\n\n## PR Review\n...",
  "content_hash": "sha256:..."
}
```

`content` 內的 PR review Markdown 與 hidden metadata 才是 review 狀態本體。Codex 不應在 cache envelope 上新增持久欄位，因為 `cache-write-comment.sh` 會重建 envelope，額外欄位可能被覆蓋。

所有 tool 必須透過既有 scripts 操作 contract：

```bash
scripts/get-pr-number.sh
scripts/cache-read-comment.sh
scripts/cache-write-comment.sh --stdin
```

禁止：

- 建立 `.pr-review-cache/pr-#-codex*.json` 或其他 review 狀態檔
- 直接使用 `gh api` 更新 canonical PR review comment
- 建立第二個 PR review comment
- 讓 Codex 自行 commit、push 或 merge

## Write Concurrency

`cache-write-comment.sh --stdin` 支援 `--expected-content-hash` 作為本地 compare-and-swap 保護；`--sync-from-cache` 仍使用 remote `updated_at` freshness check。因此 Claude、Codex、Gemini 對同一個 PR review comment 做 read-modify-write 時，應傳入讀取時看到的 cache `content_hash`。

可接受的寫入保護：

1. **Compare-and-swap（已實作，推薦）**：使用 `cache-write-comment.sh --stdin --expected-content-hash HASH`。寫入前比對現有 cache 的 `content_hash`，不一致時退出 `4`，由 dev agent 重新讀取、merge、retry。
2. **File lock**：在 `.pr-review-cache/pr-#.lock` 使用 `flock` 序列化 read-modify-write 區段。
3. **明確序列化**：dev agent 保證所有 review comment 寫入階段不並行。這只能作為 MVP 約束，不適合長期依賴。

本文後續流程要求所有 read-modify-write producer 優先使用 compare-and-swap。若某個 producer 暫時無法傳入 expected hash，dev agent 必須序列化該 producer 的寫入階段。

Bootstrap 階段也必須序列化。若兩個 tool 同時判斷沒有 comment，可能建立兩個 PR comments；後續 `find-review-comment.sh` 只會選第一個 match。dev agent 必須避免並行 bootstrap；後到者應重新執行 `cache-read-comment.sh`，若 comment 已存在則降級為 append mode。

若 race 已經發生且 PR 上存在多個 `<!-- pr-review-metadata` comments，dev agent 必須執行人工 recovery：只保留 `.pr-review-cache/pr-#.json` 的 `source_comment_id` 指向的 canonical comment，刪除或標記其他重複 comments。長期可考慮讓 `find-review-comment.sh` 在多 match 時直接 fail，而不是 warn 後取第一筆。

## Shared Metadata Schema

新 comment metadata 從單一 `skill` 模型演進為多來源模型，同時保留舊欄位相容性。

```json
{
  "schema_version": "1.1",
  "created_by": "codex-review-pass",
  "last_writer": "codex-review-pass",
  "skill": "codex-review-pass",
  "review_round": 1,
  "created_at": "2026-04-30T12:00:00Z",
  "updated_at": "2026-04-30T12:00:00Z",
  "branch": "feature-branch",
  "base": "main",
  "issues": {
    "critical": { "total": 0, "fixed": 0 },
    "important": { "total": 0, "fixed": 0 },
    "suggestions": { "total": 0, "fixed": 0 }
  },
  "review_sources": {
    "claude": {
      "last_reviewed_head": null,
      "last_reviewed_at": null,
      "agents_run": []
    },
    "gemini": {
      "consumed_comment_ids": [],
      "last_integrated_at": null
    },
    "codex": {
      "last_reviewed_head": "abc123",
      "last_reviewed_at": "2026-04-30T12:00:00Z",
      "posted_finding_ids": []
    }
  }
}
```

`created_by` 表示第一次建立 canonical review comment 的 producer。`last_writer` 表示最後一次更新 comment 的 skill。`skill` 是 legacy 欄位；bootstrap 時設為 `last_writer`（也就是與 `created_by` 相同），append/upgrade 既有 1.0 comment 時可保留舊值一個過渡 release。新版邏輯應優先讀取 `review_sources`。

`review_round` 是 PR-global review producer 輪次，不是 per-source 輪次。`pr-review-and-document` 與 `codex-review-pass` 這類 review producer 在產生含有新增 findings 的 review pass 時應 increment；空 review pass 只更新 source timestamp，不 increment。`gemini-review-integrator` 只整合外部 comment，不 increment；`codex-fix-worker` 與 `pr-review-resolver` 只修復或更新狀態，也不 increment。

`Reviewer Sources` 顯示行是由 metadata 派生的 UI 字串，依固定順序 `Claude, Gemini, Codex` 列出有參與的 source。參與判斷：Claude/Codex 使用 `last_reviewed_at != null`，Gemini 使用 `last_integrated_at != null` 或 `consumed_comment_ids` 非空。

### Metadata Migration

每個會寫 metadata 的 skill 在 read 時都要做 upgrade，write 時統一寫 comment metadata schema `1.1`。優先使用 shared helper，避免 Claude/Codex 各自重寫 migration：

```bash
review-metadata-upgrade.sh --stdin --last-writer <skill-name>
```

After modifying the returned JSON, use the paired helper to put it back into the comment without touching issue sections:

```bash
review-metadata-replace.sh --stdin --metadata-file <metadata-json-file>
```

| 1.0 欄位 | 1.1 欄位 | 規則 |
|---|---|---|
| `schema_version` | `schema_version` | comment metadata 升為 `"1.1"`；cache envelope 不變 |
| `skill` | `created_by`, `last_writer`, `skill` | 若 `created_by` 不存在，以舊 `skill` 初始化；`last_writer` 設為目前寫入者；`skill` 保留為 legacy |
| `agents_run` | `review_sources.claude.agents_run` | 搬移到 Claude source；Phase 2 寫入時 top-level 與 nested 同時保留，read 時優先 nested；移除 top-level 必須另開 release 並寫入 release notes |
| `gemini_integrated_ids` | `review_sources.gemini.consumed_comment_ids` | numeric GitHub comment IDs；避免與 Codex finding IDs 混淆 |
| `gemini_integration_date` | `review_sources.gemini.last_integrated_at` | 保留整合時間 |
| 無 | `review_sources.codex.posted_finding_ids` | Codex 自產 finding IDs |

不支援 downgrade。多來源 metadata 上線後，不應再使用舊版 Claude skills 寫回同一個 PR review comment，否則可能抹掉 `review_sources` 與 `[Codex]` issues。

## codex-review-pass

`codex-review-pass` 是 Codex 的 review producer。它必須支援兩種模式。

### Environment Contract

Codex skills 需要知道 toolkit root。建議約定：

```text
PR_REVIEW_TOOLKIT_ROOT=/path/to/pr-review-toolkit
```

解析順序：

1. 若環境變數 `PR_REVIEW_TOOLKIT_ROOT` 存在，使用它。
2. 若 Codex packaging 提供 wrapper script，wrapper 以自身相對路徑解析 repo root。
3. 若都不存在，停止並要求 dev agent 提供 toolkit root。

不要在 Codex skill 中使用 `${CLAUDE_PLUGIN_ROOT}`；那是 Claude Code plugin runtime 的環境變數。

### Bootstrap Mode

當尚未存在 canonical PR review comment 時，Codex 可以成為第一步：

```text
codex-review-pass
→ creates canonical PR review comment
→ creates .pr-review-cache/pr-#.json through cache-write-comment.sh
```

判斷方式：

```bash
PR_NUMBER=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/get-pr-number.sh")

set +e
REVIEW_CONTENT=$("${PR_REVIEW_TOOLKIT_ROOT}/scripts/cache-read-comment.sh" "$PR_NUMBER")
EXIT_CODE=$?
set -e

case "$EXIT_CODE" in
  0) MODE="append" ;;
  2) MODE="bootstrap" ;;
  *) exit "$EXIT_CODE" ;;
esac
```

Bootstrap comment 必須使用既有 marker：

```markdown
<!-- pr-review-metadata
{
  "schema_version": "1.1",
  "created_by": "codex-review-pass",
  "last_writer": "codex-review-pass",
  "skill": "codex-review-pass",
  "review_round": 1,
  "review_sources": {
    "claude": { "last_reviewed_head": null, "last_reviewed_at": null, "agents_run": [] },
    "gemini": { "consumed_comment_ids": [], "last_integrated_at": null },
    "codex": {
      "last_reviewed_head": "abc123",
      "last_reviewed_at": "2026-04-30T12:00:00Z",
      "posted_finding_ids": ["codex:src/foo.ts:symbol-name:error-propagation:abcd1234"]
    }
  }
}
-->

## PR Review

**Reviewer Sources:** Codex

### Summary

### Critical Issues

### Important Issues

<details>
<summary><b>1. ⚠️ [Codex] Missing error propagation</b></summary>

**Source:** Codex  
**File:** `src/foo.ts:42`

**Problem:** ...

**Fix:** ...

</details>

### Suggestions

### Action Plan
```

### Append Mode

當 comment 已存在時，Codex 應：

1. 讀取現有 metadata 與 issue sections
2. 將 metadata in-memory upgrade 到 `1.1`
3. review 目前 PR diff / working tree
4. 產生 finding ID
5. 依 `review_sources.codex.posted_finding_ids` 與現有 section 內容去重
6. 只插入新的 Codex findings
7. 若有新增 finding，increment PR-global `review_round`；若沒有新發現，只更新 `last_reviewed_head` / `last_reviewed_at`，不 increment
8. 更新 summary counts、`updated_at`、`last_writer`、`review_sources.codex`
9. 透過 `cache-write-comment.sh --stdin` 寫回

Codex finding 一律標示來源：

```markdown
<summary><b>N. ⚠️ [Codex] Issue title</b></summary>

**Source:** Codex
```

Claude 既有 issue 沒有 `[Claude]` prefix；新版 resolver 應明確約定「沒有來源 prefix 的 issue 視同 Claude」。Gemini 與 Codex issue 則以 `[Gemini]` / `[Codex]` 區分。

若沒有新發現，仍可更新 `last_reviewed_head` 與 `last_reviewed_at`，但不應改動既有 issue 狀態。

### Finding ID

Codex finding ID 是 best-effort 去重機制，不保證跨輪 100% 穩定。建議格式：

```text
codex:<file>:<symbol-or-nearest-heading>:<diagnostic-kind>:<snippet-hash>
```

避免只使用絕對行號，因為修復後行號容易漂移。`snippet-hash` 應來自相關程式碼片段或 diff hunk，而不是自然語言 title。若仍發生重複，`pr-review-resolver` 或 dev agent 可將重複 issue 標記為 `⏭️ Duplicate`。

## codex-fix-worker

`codex-fix-worker` 是 Codex 的 bounded implementation skill。它修復 dev agent 指派的一個 review issue，並更新同一份 canonical review comment 中該 issue 的狀態。

必要輸入：

```text
PR number: 123
Issue source: Claude / Gemini / Codex
Issue title: ...
Issue file references:
- path/to/file.ts:42
Decision:
Fix using approach X.
Owned files:
- path/to/file.ts
```

工作流程：

1. 讀取 `.pr-review-cache/pr-#.json`，確認目標 issue 仍是 `⚠️` 或 `🔴`
2. 將 metadata in-memory upgrade 到 `1.1`
3. 只修改 owned files；若必須修改其他檔案，停止並回報 dev agent
4. 執行相關驗證，例如測試、lint、`git diff --check`
5. 修完後重新讀取最新 cache，並使用 compare-and-swap 或 dev-agent 序列化避免覆蓋其他 tool 更新
6. 將該 issue 狀態改為 `✅`，補上修復摘要與 validation
7. 保持既有 `review_round` 不變
8. 使用 `cache-write-comment.sh --stdin` 寫回
9. 回報 modified files、validation result、remaining risk、commit message draft

`codex-fix-worker` 可以：

- 修改 code
- 更新該 issue 的狀態與修復說明
- 更新 summary counts 與 metadata timestamp

`codex-fix-worker` 不可以：

- 自行把 issue 標記為 Deferred 或 N/A
- 修改無關 issue 狀態
- 重寫整份 review comment 架構
- 建立新 cache 檔或新 PR comment
- commit、push、merge

Output contract：

```text
Files changed:
- path/to/file.ts

Validation:
- npm test -- ...

Review comment update:
- Marked "[Codex] Missing error propagation" as fixed.

Commit message draft:
fix(scope): address missing error propagation

Remaining risk:
- ...
```

dev agent 或人類負責 commit / push。Codex 修改完但未 commit 前，不應啟動下一輪 review pass，避免 review 工具把未整理的 working tree 當成噪音。

## Cross-Tool Workflow

Claude-first workflow：

```text
Claude:    pr-review-and-document
Claude:    gemini-review-integrator
Codex:     codex-review-pass
Codex:     codex-fix-worker for selected issues
dev agent: commit fix-worker changes
Claude:    pr-review-resolver when human decision is needed
```

Codex-first workflow：

```text
Codex:     codex-review-pass
Claude:    gemini-review-integrator
Codex:     codex-fix-worker for selected issues
dev agent: commit fix-worker changes
Claude:    pr-review-resolver when human decision is needed
```

Loop：

```text
Claude or Codex: review pass
Codex or Claude: fix selected issues
dev agent:       commit changes
Claude:          resolver for ambiguous decisions
repeat until Summary shows no remaining blocking issues
```

## Packaging and Distribution Plan

This repository should remain the source of truth for both ecosystems.

Current Claude Code distribution:

```text
.claude-plugin/plugin.json
.claude-plugin/marketplace.json
skills/*/SKILL.md
commands/*.md
scripts/*.sh
```

Proposed Codex distribution layout:

```text
codex/
├── skills/
│   ├── codex-review-pass/
│   │   └── SKILL.md
│   └── codex-fix-worker/
│       └── SKILL.md
└── plugin.json or marketplace metadata, pending Codex distribution requirements
```

The Codex skills should reuse the root `scripts/` directory instead of copying cache logic. If Codex packaging requires self-contained skill folders, use thin wrapper scripts that delegate to the root scripts, and keep the root scripts authoritative.

Release requirements:

- Claude plugin version remains authoritative in `.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json` plugin version must match `.claude-plugin/plugin.json`
- Codex package metadata should use the same semantic version
- Release validation should check Claude metadata, Codex metadata, and cross-package version consistency once Codex packaging is added
- `CHANGELOG.md` should include one release stream covering both install targets

Open packaging question:

- The exact Codex marketplace / install metadata format must be confirmed before implementation. Until then, keep Codex-specific files under `codex/` and avoid changing Claude marketplace metadata.

## Implementation Phases

### Phase 0: Design & Review

- Add this design document
- Review the contract, migration, concurrency, and packaging assumptions
- Do not change runtime behavior yet

### Phase 1: Contract Safety

- Add compare-and-swap support to `cache-write-comment.sh --stdin`
- Add shared metadata migration helper and fixtures for schema `1.0` to `1.1`
- Add shared metadata replacement helper and preservation fixtures
- Document retry behavior for content hash mismatches
- Add tests or validation commands for cache write behavior

### Phase 2: Multi-Source Compatibility Release

Phase 2 must ship Claude compatibility updates and Codex skill scaffolding together. Do not enable Codex skills before Claude skills preserve Codex metadata and issue sections.

- Update `pr-review-and-document` to merge existing metadata and issue sections instead of blindly regenerating the whole comment
- Update `gemini-review-integrator` to migrate and preserve `review_sources`
- Update `pr-review-resolver` to recognize `[Codex]` issues and untagged Claude issues
- Add `codex/skills/codex-review-pass/SKILL.md`
- Add `codex/skills/codex-fix-worker/SKILL.md`
- Ensure both Codex skills use only `cache-read-comment.sh` and `cache-write-comment.sh` for review state

### Phase 3: Packaging

- Add Codex package metadata after confirming the target format
- Extend validation workflow to check Codex skill files and metadata
- Update `README.md` installation docs for both Claude Code and Codex
