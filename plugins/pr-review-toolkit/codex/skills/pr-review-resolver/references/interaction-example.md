# pr-review-resolver Interaction Example

Use this as the interaction model for Codex. The resolver speaks Traditional Chinese, discusses one issue at a time, and only dispatches fix work after the user decides.

## Start

```text
Codex: 我找到 3 個尚未解決的 review 項目。我會逐一處理；每一項都會先確認原始碼狀態，再由你決定修復、延後、標記 N/A，或暫時跳過。
```

## Present One Issue

```text
問題 1/3：Silent Cart Quantity Fetch Failure

來源：Codex
位置：apps/client/src/lib/context/cart-drawer-context.tsx:59
狀態：仍需處理

問題摘要：
目前 API 失敗時 cart quantity 會退回 0，使用者可能在購物車有商品時看到空 badge。這會造成誤導，也會讓除錯困難。

我先檢視 referenced code，確認問題是否仍存在。
```

After reading the file:

```text
我確認問題仍存在。可選處理方式：

1. 修復：讓 context 暴露錯誤狀態，UI 可顯示失敗狀態或保留上一個可靠值。
2. 延後：如果這個 PR 不想碰 UI 狀態模型，可以記錄原因並留到下一個 PR。
3. 標記 N/A：如果產品明確接受失敗時顯示 0，可以把這個設計決策寫在相關程式碼旁。
4. 暫時跳過：稍後再回來處理。

你要怎麼處理這一項？
```

## User Chooses Fix

```text
Codex: 了解，這項走「修復」。

Owned files:
- apps/client/src/lib/context/cart-drawer-context.tsx

目前沒有其他修復工作占用這個檔案。我會啟動一個 bounded fix worker 處理這個單一 issue，並繼續看下一項。
```

## User Chooses Deferred Or N/A

```text
Codex: 了解，這項標記為 Deferred。

我會在相關程式碼附近加入自包含的 Design Decision 註解，並在 review comment 中把這項改成 ⏭️ Deferred，原因是：
<user-provided reason>
```

## Final Collection

```text
處理總覽：

| # | 問題 | 來源 | 決策 | 狀態 |
|---|------|------|------|------|
| 1 | Silent Cart Quantity Fetch Failure | Codex | 修復 | ✅ Fixed |
| 2 | Missing Error Boundary | Claude | 延後 | ⏭️ Deferred |
| 3 | Outdated Comment | Gemini | N/A | ⏭️ N/A |

我會更新 canonical review comment，保持 review_round 不變，並同步 `.pr-review-cache/pr-123.json`。
```
