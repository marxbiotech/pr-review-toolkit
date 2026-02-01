---
name: pr-review-resolver
description: 當使用者要求「處理 PR review 問題」、「修復 review 項目」、「解決 PR 回饋」、「逐一處理 review issues」、「完成 review 任務」、「run pr review resolver」時使用此 skill。讀取當前分支 PR 的 review comment，**逐一**與使用者討論每個未解決的問題，由使用者決定處理方式。
---

# PR Review Resolver

互動式解決 PR review comment 中的未解決問題。

**重要原則：**
1. **永遠使用繁體中文（zh-TW）** 與使用者溝通
2. **逐一處理**每個問題，不要批次處理
3. **由使用者決定**處理方式，不要自行決定

## 使用時機

當需要：
- 處理 PR review 中的未解決問題
- 解決先前 review session 的回饋
- 在 merge 前完成剩餘任務
- 討論如何處理特定的 review 發現

## 工作流程

### 步驟 1：取得 PR Review Comment

首先確認 PR 存在：

```bash
gh pr view --json number -q '.number'
```

若無 PR，通知使用者並停止。

接著找到 review comment：

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/find-review-comment.sh
```

若有回傳 comment ID，取得 comment 內容：

```bash
gh api "/repos/{owner}/{repo}/issues/comments/{COMMENT_ID}" --jq '.body'
```

若找不到 review comment，通知使用者先執行 `pr-review-and-document` skill。

### 步驟 2：解析未解決項目

從 review comment 中識別所有未解決項目：

**未解決指標：**
- `⚠️` 需要注意的項目（待處理）
- `🔴` 阻擋性問題（必須在 merge 前解決）
- 表格中的 `⚠️ Pending` 狀態
- 沒有 `✅` 或 `⏭️` 前綴的 details summary
- 「Action Plan」中沒有完成標記 `[x]` 的任務

**已解決指標：**
- `✅` 問題已解決（程式碼變更已完成）
- `⏭️` 刻意延後或不適用（標記為 Deferred / N/A / Kept）
- `[x]` 已勾選的 checkbox

### 步驟 3：逐一處理每個項目（最重要！）

**關鍵要求：必須一次只處理一個項目，等待使用者回應後才能繼續下一個。**

對於 **每一個** 未解決項目，依序執行：

#### 3.1 清楚呈現問題

用繁體中文向使用者說明：
- 引用 review 中的問題描述
- 顯示 file:line 參考位置
- 解釋問題及其影響

#### 3.2 閱讀實際原始碼

- 使用 Read 工具檢視被參考的檔案
- 驗證問題是否仍然存在
- 檢查是否已在最近的 commit 中修復

#### 3.3 與使用者討論（必要！）

**這是最重要的步驟。必須：**
- 用繁體中文解釋可能的解決方案
- 如果有多種方法，以選項形式呈現
- 使用 AskUserQuestion 工具或 `<options>` 讓使用者選擇
- **等待使用者決定後才能繼續**

選項範例：
```
這個問題有幾種處理方式：

1. **修復** - [說明修復方法]
2. **延後** - [說明為何可以延後]
3. **標記為 N/A** - [說明為何不適用]

<options>
<option>修復這個問題</option>
<option>延後到下個 PR</option>
<option>標記為不適用 (N/A)</option>
</options>
```

#### 3.4 依使用者決定執行

- 若使用者選擇 **修復**：實施修復，記錄狀態為 `✅ Fixed`
- 若使用者選擇 **延後**：記錄狀態為 `⏭️ Deferred`，加上原因
- 若使用者選擇 **標記 N/A**：記錄狀態為 `⏭️ N/A`，加上說明

#### 3.5 在原始碼中記錄決策

對於標記為 N/A 或 Deferred 的項目，在相關原始碼中加入註解：
- 註解格式：`// Design Decision: [原因] @see PR #N review comment`
- 這可防止相同問題在未來的 review 中再次出現

#### 3.6 確認後才能繼續下一個項目

**必須等待當前項目完全解決後，才能處理下一個項目。**
向使用者確認：「這個問題已處理完成。繼續處理下一個問題？」

### 步驟 4：更新 Review Comment

所有項目處理完成後，更新 PR review comment：

1. 準備更新後的內容：
   - 更新各項目的狀態指標
   - 更新 Summary 表格的計數
   - 更新 metadata 中的 `updated_at` 和 issues 計數
   - 將 Status 更新為適當狀態

2. 寫入臨時檔案並更新 comment：

```bash
TEMP_FILE=$(mktemp)
# 將更新後的內容寫入 $TEMP_FILE
${CLAUDE_PLUGIN_ROOT}/scripts/upsert-review-comment.sh "$TEMP_FILE"
rm -f "$TEMP_FILE"
```

### 步驟 5：知識萃取（所有項目完成後）

當所有項目都解決後，分析此次 session 的學習：

1. **識別模式：**
   - 適用於多個檔案的決策
   - 新建立的慣例
   - 對現有指南的澄清

2. **檢查是否需要更新 CLAUDE.md：**
   - 是否有決策澄清了模糊的指南？
   - 是否建立了應該記錄的新模式？
   - 是否發現了缺少的指南參考？

3. **必要時建立文件：**
   - 將新指南加入適當的 `docs/` 檔案
   - 用漸進式揭露方式更新 CLAUDE.md
   - 格式：CLAUDE.md 中放簡要摘要，docs/ 中放完整詳情

4. **更新 review comment：**
   - 在最後加入「Knowledge Extracted」章節
   - 列出任何建立或更新的指南
   - 參考文件變更

## 決策記錄格式

標記項目為 N/A 或 Deferred 時，在原始碼中加入註解：

```typescript
// Design Decision: [決策的簡要原因]
// Rationale: [如需要，更詳細的說明]
// @see PR #N review comment
```

範例：
```typescript
// Design Decision: 為可讀性保留明確的 null 檢查
// Rationale: 抽象成 helper 會降低清晰度，收益不大
// @see PR #42 review comment
```

## 狀態指標

更新 review 時使用一致的狀態指標：

| 指標 | 意義 | 使用時機 |
|------|------|----------|
| ✅ | 問題已解決 | 程式碼變更已完成並驗證 |
| ⏭️ | 刻意延後或不適用 | 將在未來處理或設計考量 |
| ⚠️ | 需要注意 | 仍需處理 |
| 🔴 | 阻擋性問題 | 必須在 merge 前解決 |

## 知識萃取標準

評估每個已解決項目是否需要知識萃取：

| 決策類型 | 萃取到 CLAUDE.md？ | 範例 |
|----------|-------------------|------|
| 一次性修復 | 否 | 錯字修正、簡單 bug |
| 模式澄清 | 是 | 「日期排序使用 localeCompare」 |
| 新慣例 | 是 | 「所有 response DTO 使用 snake_case」 |
| 指南例外 | 是 | 「CMS 錯誤使用優雅降級」 |
| 工具偏好 | 是 | 「條件式 className 使用 clsx」 |

### CLAUDE.md 更新格式

萃取知識時，遵循漸進式揭露：

**在 CLAUDE.md 中（簡要參考）：**
```markdown
#### [類別] 指南

詳見 [`docs/[guideline-file].md`](docs/[guideline-file].md)。

**核心原則**：[一句話摘要]

**必須參考的情境：**
1. [觸發情境 1]
2. [觸發情境 2]
```

**在 docs/ 中（完整詳情）：**
```markdown
# [指南標題]

## 背景

[為何需要此指南]

## 模式

[帶範例的詳細說明]

## 使用時機

[適用的情境]

## 例外

[不適用的情況]
```

## 驗證清單

完成 review 解決 session 前：

- [ ] 所有項目都有狀態（✅、⏭️ 或明確決策）
- [ ] N/A 和 Deferred 項目有原始碼註解
- [ ] PR review comment 已更新解決方案
- [ ] 已評估知識萃取
- [ ] 任何新指南已記錄並參考
- [ ] Review comment 中的 Summary 計數已更新

## 互動範例

以下是正確的互動流程範例：

```
Claude: 我找到了 3 個未解決的問題。讓我們逐一處理。

**問題 1/3：Silent Cart Quantity Fetch Failure**

📍 位置：`apps/client/src/lib/context/cart-drawer-context.tsx:59-60`

🔍 問題：Cart 數量在 API 失敗時會默默地變成 0。使用者在有商品的情況下會看到空的購物車 badge。

💡 影響：使用者體驗受損，可能導致重複加入商品。

讓我先檢視實際的原始碼...

[讀取檔案後]

目前的程式碼確實沒有處理錯誤狀態。有以下處理方式：

1. **修復** - 加入 `isError` 到 context value，讓 UI 可以顯示錯誤狀態
2. **延後** - 這是 edge case，可在下個 PR 處理
3. **標記為 N/A** - 如果認為 0 是可接受的 fallback

你想要怎麼處理這個問題？

<options>
<option>修復這個問題</option>
<option>延後到下個 PR</option>
<option>標記為不適用 (N/A)</option>
</options>
```

**使用者回應後，才能繼續處理問題 2/3。**

## 無 PR 或無 Review Comment 的處理

- **無 PR**：通知使用者先建立 PR（`gh pr create`）
- **無 Review Comment**：通知使用者先執行 `pr-review-and-document` skill 產生 review
