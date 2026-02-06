---
name: enable-subagents
description: 當使用者要求「啟用 subagent」、「配置 subagent 權限」、「enable subagents」、「設定 agent 環境」、「fix subagent permissions」時使用此 skill。幫助使用者配置 Claude Code 環境，確保 pr-review-resolver 等 skill 使用的 subagent 不會遇到權限問題。
disable-model-invocation: true
allowed-tools: Read, Edit, Write, Bash(mkdir *)
---

# Enable Subagents

幫助使用者配置 Claude Code 環境，讓 subagent 可以正常執行需要的操作。

**重要原則：**
1. **永遠使用繁體中文（zh-TW）** 與使用者溝通
2. **先檢查再更新**，只新增缺少的權限
3. **保留現有配置**，不覆蓋使用者其他設定

## 使用時機

當需要：
- 啟用 pr-review-resolver 等 skill 的 subagent 功能
- 修復 subagent 權限被阻擋的問題
- 在新專案或新環境配置 Claude Code 權限
- 確保 plugin scripts 可被 subagent 執行

## 背景說明

pr-review-resolver 等 skill 會啟動 subagent 來執行任務。Subagent 需要以下權限：

| 權限 | 用途 |
|------|------|
| `Read` | 讀取原始碼驗證問題 |
| `Edit` | 修復問題時修改檔案 |
| `Write` | 寫入檔案（修復問題時建立或修改檔案） |
| `Bash(mkdir:*)` | 建立必要目錄 |
| `Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)` | 執行 plugin scripts |

當這些操作在 subagent 中執行時，需要父會話已經有對應權限，否則會被阻擋。

## 工作流程

### 步驟 1：選擇配置層級

使用 AskUserQuestion 詢問使用者偏好的配置層級：

```
請選擇要配置權限的層級：

**User-level** (`~/.claude/settings.json`)
- 套用到所有專案
- 適合經常使用 pr-review-toolkit 的使用者

**Project-level** (`.claude/settings.json`)
- 只影響當前專案
- 適合想要限制權限範圍的使用者
- 可加入版本控制讓團隊共享

<options>
<option>User-level（套用到所有專案）</option>
<option>Project-level（只影響當前專案）</option>
</options>
```

### 步驟 2：檢查現有配置

根據使用者選擇的層級，讀取對應的 settings.json：

- User-level: `~/.claude/settings.json`
- Project-level: `.claude/settings.json`

如果檔案不存在，準備建立新檔案。

解析現有的 `permissions.allow` 陣列（如果存在）。

### 步驟 3：識別缺少的權限

需要配置的權限清單：

```json
[
  "Read",
  "Edit",
  "Write",
  "Bash(mkdir:*)",
  "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)"
]
```

比對現有配置，列出缺少的權限。

### 步驟 4：說明與確認

向使用者說明：

1. **如果已全部配置**：告知使用者權限已完整，不需要任何變更，然後結束。

2. **如果有缺少的權限**：
   - 列出將要新增的每個權限及其用途
   - 顯示完整的配置預覽
   - 使用 AskUserQuestion 確認使用者同意更新

範例說明格式：

```
目前缺少以下權限：

1. `Read` - 讓 subagent 可以讀取原始碼檔案驗證問題
2. `Write` - 讓 subagent 可以寫入臨時檔案

更新後的配置將是：

{
  "permissions": {
    "allow": [
      "Read",
      "Edit",
      "Write",
      "Bash(mkdir:*)",
      "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)"
    ]
  }
}

<options>
<option>確認更新配置</option>
<option>取消</option>
</options>
```

### 步驟 5：更新配置

使用者確認後：

1. **建立目錄**（如需要）：
   - User-level: 確保 `~/.claude/` 存在
   - Project-level: 確保 `.claude/` 存在

2. **合併配置**：
   - 如果檔案已存在，讀取並解析 JSON
   - 保留所有現有設定
   - 只新增 `permissions.allow` 中缺少的項目
   - 不刪除或覆蓋任何現有權限

3. **寫入配置**：
   - 使用正確的 JSON 格式（2 空格縮排）
   - 確保檔案以換行結尾

### 步驟 6：驗證並通知

1. 重新讀取配置檔確認變更成功
2. 顯示最終配置摘要
3. 提示使用者：「配置已更新。如果 Claude Code 正在執行中，可能需要重新啟動才能套用新權限。」

## 配置範例

### 最小配置（新建立）

```json
{
  "permissions": {
    "allow": [
      "Read",
      "Edit",
      "Write",
      "Bash(mkdir:*)",
      "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)"
    ]
  }
}
```

### 合併到現有配置

假設現有配置：

```json
{
  "theme": "dark",
  "permissions": {
    "allow": [
      "Read",
      "Bash(git:*)"
    ]
  }
}
```

更新後：

```json
{
  "theme": "dark",
  "permissions": {
    "allow": [
      "Read",
      "Bash(git:*)",
      "Edit",
      "Write",
      "Bash(mkdir:*)",
      "Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)"
    ]
  }
}
```

## 錯誤處理

- **JSON 解析失敗**：通知使用者現有配置檔格式有誤，詢問是否要備份後重建
- **寫入失敗**：顯示錯誤訊息，建議檢查目錄權限
- **使用者取消**：確認不做任何變更，結束 skill

## 驗證清單

完成配置前確認：

- [ ] 使用者已選擇配置層級（User-level 或 Project-level）
- [ ] 現有配置已正確讀取（若存在）
- [ ] 只新增缺少的權限，未覆蓋現有設定
- [ ] 使用者已確認變更內容
- [ ] 配置檔案已成功寫入
- [ ] 已驗證變更生效
- [ ] 已提示使用者可能需要重新啟動 Claude Code

## 完成後的驗證

配置完成後，建議使用者：

1. 執行 `/pr-review-resolver` 測試 subagent 是否正常運作
2. 如果仍有權限問題，檢查 Claude Code 是否需要重新啟動

**成功指標：**
- Subagent 可以讀取和編輯檔案，不再出現權限提示
- Plugin scripts 可以正常執行
- 不需要在每次 subagent 操作時手動確認權限
