# 互動範例

以下是正確的互動流程範例（含並行背景子任務）。

## 逐一呈現問題

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

## 使用者選擇「修復」後

```
Claude: 目標檔案：`cart-drawer-context.tsx`。沒有其他子任務正在修改此檔案。

🔧 已啟動背景子任務修復此問題。

✓ 已記錄。接下來看下一個問題（2/3）。

---

**問題 2/3：Missing Error Boundary in Checkout**

📍 位置：`apps/client/src/components/checkout/payment-form.tsx:120-135`
...
```

## 所有問題討論完畢後，進入驗收階段

```
Claude:
📊 處理總覽：
- 🔧 修復中：2 個（背景子任務進行中）
- ⏭️ 延後：1 個

正在等待子任務完成...

✅ 問題 1（Silent Cart Failure）— 修復完成
✅ 問題 3（Unused Import）— 修復完成

驗證修改範圍... 所有變更都在預期檔案內。

| # | 問題 | 決策 | 狀態 |
|---|------|------|------|
| 1 | Silent Cart Failure | 修復 | ✅ Fixed |
| 2 | Missing Error Boundary | 延後 | ⏭️ Deferred |
| 3 | Unused Import | 修復 | ✅ Fixed |
```
