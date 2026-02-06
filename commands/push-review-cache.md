---
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cache-write-comment.sh *)
description: 將本地快取的 PR review comment 重新同步至 GitHub。用於 GitHub 同步失敗後的 recovery，或手動推送本地變更。
argument-hint: [PR_NUMBER] [force]
---

# Push Review Cache to GitHub

將本地快取中的 PR review comment 推送至 GitHub。

## 安全機制

推送前會自動比對本地 `cached_at` 與遠端 `updated_at`：
- **本地較新** → 正常推送
- **遠端較新** → 中止並警告（exit code 3），避免覆蓋他人更新
- **加上 `force`** → 跳過時間戳檢查，強制推送

## 使用時機

- `cache-write-comment.sh` 的 GitHub 同步失敗後，需要重試上傳
- 使用者說「重新同步 review」、「push review cache」、「retry sync」
- 本地快取已更新但 GitHub 尚未同步

## 前置條件

- 本地快取存在（`.pr-review-cache/pr-{PR_NUMBER}.json`）
- 已安裝 GitHub CLI (`gh`) 並完成認證

## 使用方式

```
/push-review-cache [PR_NUMBER]
/push-review-cache [PR_NUMBER] force
```

若不提供 PR_NUMBER，會自動從當前分支取得。

## 執行

解析參數，判斷是否包含 `force`：

- 若 `$ARGUMENTS` 包含 `force`，從參數中取出 PR_NUMBER（非 "force" 的部分）並加上 `--force` 旗標
- 若 `$ARGUMENTS` 不包含 `force`，直接傳遞所有參數

```bash
ARGS="$ARGUMENTS"
FORCE_FLAG=""
PR_NUM=""

for word in $ARGS; do
  case "$word" in
    force|--force) FORCE_FLAG="--force" ;;
    *) PR_NUM="$word" ;;
  esac
done

${CLAUDE_PLUGIN_ROOT}/scripts/cache-write-comment.sh --sync-from-cache $PR_NUM $FORCE_FLAG
```

回報執行結果給使用者：
- 成功（exit 0）：顯示 GitHub comment URL
- 遠端較新（exit 3）：告知使用者遠端有更新的版本，詢問是否要 force push 或先用 `/pr-cache-sync` 拉取最新版本
- 同步失敗（exit 1）：顯示錯誤訊息，建議檢查網路連線或 GitHub token 權限
