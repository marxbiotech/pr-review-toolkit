# Codex Integration Design — Claude Review

> Reviewer: Claude (Opus 4.7)
> Reviewed: `docs/codex-integration-design.md`
> Date: 2026-04-30
> Repo state at review: `main` @ f60e8ee, plugin v1.4.2

本文記錄對 `codex-integration-design.md` 的設計審查結論。已對照 `scripts/cache-read-comment.sh`、`scripts/cache-write-comment.sh`、`scripts/find-review-comment.sh`、`skills/pr-review-and-document/SKILL.md`、`skills/gemini-review-integrator/SKILL.md` 驗證每一條假設，並標注實際 file:line。

---

## 總體評價

設計方向合理：堅守單一 cache contract、要求 Codex 透過既有 scripts 寫回、明確切分 review producer 與 fix worker 的職責，並用 phasing 避免一次更動 Claude runtime。但**現有 metadata schema 的相容性、Phase ordering 的安全性、以及多 tool 並行寫入的 race condition** 在文件裡尚未完整處理，落地前必須補上。

---

## 必須處理（Blocking）

### 1. Phase 2 與 Phase 3 不能拆開上線（regression risk）

`skills/pr-review-and-document/SKILL.md:62-191` 的 Step 4–5 是「**重新生成整份 comment**」並透過 `cache-write-comment.sh --stdin` 寫回，現行 metadata template (line 80–96) 完全不知道 `review_sources.codex` 的存在。

如果文件描述的 Phase 2（新增 `codex-review-pass` / `codex-fix-worker`）先於 Phase 3（更新 Claude skills 保留 `review_sources.codex`）上線，發生順序：

1. Codex 透過 `codex-review-pass` (append mode) 在 metadata 加 `review_sources.codex` 與 `[Codex]` issues。
2. 使用者下一輪跑 Claude `pr-review-and-document`。
3. Claude skill regenerate template，**抹掉** `review_sources.codex`、Codex issues、所有 Codex 加上的 `integrated_ids`。

**修正建議**：
- Phase 2 與 Phase 3 必須**同一個 release** 上線，或調換 phase 順序（先教 Claude 認得 Codex metadata，再放出 Codex skills）。
- 在 Phase 2 描述加上紅字提醒：在 Claude skills 還沒升級前，Codex skills 不得實際投入工作流程。
- `pr-review-and-document` SKILL.md 需要新增一個「合併既有 metadata 與既有 issue sections」的 step，而不是純 regenerate；這項工作目前沒有被 Phase 3 細項涵蓋。

### 2. 1.0 → 1.1 metadata 缺少 migration 規格

文件 §Shared Metadata Schema（line 70–95）給出 1.1 範例，但**沒有定義 1.0 → 1.1 的轉換規則**。實際 1.0 schema（`skills/pr-review-and-document/SKILL.md:80-96` 與 `skills/gemini-review-integrator/SKILL.md:138-145`）有以下欄位**未在 1.1 範例中出現**：

| 1.0 欄位 | 來源 | 1.1 範例的處理 |
|---|---|---|
| `agents_run` | `pr-review-and-document` | **完全消失**，且無對應 `review_sources.claude.*` 欄位 |
| `gemini_integrated_ids` (top-level, numeric GitHub comment IDs) | `gemini-review-integrator` | 隱含遷移到 `review_sources.gemini.integrated_ids`，但未明寫 |
| `gemini_integration_date` (top-level) | `gemini-review-integrator` | 隱含 → `review_sources.gemini.last_reviewed_at`，但未明寫 |

文件聲稱「保留舊欄位相容性」（line 68），但範例（line 70–95）並沒有保留這些欄位。讀寫衝突真實存在：舊 parser 找不到欄位 → 假裝 Gemini 從未整合過 → 重複寫入。

**修正建議**：
- 在 §Shared Metadata Schema 增加 **Migration Table**，明確列出 1.0 欄位 → 1.1 欄位映射，包含 `agents_run`、`gemini_integrated_ids`、`gemini_integration_date`。
- 將 `agents_run` 放入 `review_sources.claude.agents_run`（或頂層保留），並在 1.1 範例展示之。
- 規定每個會寫 metadata 的 skill 在 read 時都要做 in-memory upgrade（1.0 → 1.1），write 時統一寫 1.1。
- 補上 down-grade 策略（或明確說「不支援 down-grade，新版本上線後不可回退」）。

### 3. `--stdin` 寫入路徑沒有 freshness check（concurrent write 會吃單）

`scripts/cache-write-comment.sh:106-136` 的 freshness check（比對 `LOCAL_CACHED_AT` vs remote `updated_at`）**只在 `--sync-from-cache` 模式生效**；正常的 `--stdin` 寫入完全沒有這個保護。

文件 §codex-fix-worker step 4「修完後重新讀取最新 cache，降低覆蓋其他 tool 更新的風險」(line 219) 是 *mitigation*，不是 *solution* —— 它縮小 TOCTOU 窗口但無法消除。場景：

1. Codex `cache-read-comment.sh` 讀到 cache vN。
2. 同時 Claude `pr-review-and-document` 寫入 vN+1。
3. Codex 完成修改，`cache-write-comment.sh --stdin` 寫入「以 vN 為基礎的修改」 → 直接覆蓋 vN+1。

考慮到設計文件描述的「Claude-first / Codex-first / loop」工作流，這個 race 並非邊界 case。

**修正建議（擇一或組合）**：
- 在 `cache-write-comment.sh --stdin` 加入 optional `--expected-content-hash` 旗標，提供 compare-and-swap：寫入前比對 cache 上的 `content_hash`，不符就退出 4。
- 或引入 `.pr-review-cache/pr-#.lock` flock，序列化 read-modify-write 區段。
- 設計文件須明寫「目前不支援真正的並行寫入；dev agent 必須序列化 Claude / Codex 的 write 階段」，並加上 retry 流程。

### 4. `${PR_REVIEW_TOOLKIT_ROOT}` 未定義在何處解析

文件 §Bootstrap Mode (line 116–122) 與多處用 `${PR_REVIEW_TOOLKIT_ROOT}/scripts/...`，但 Claude 既有 skills 一律是 `${CLAUDE_PLUGIN_ROOT}/scripts/...`（如 `skills/pr-review-and-document/SKILL.md:23`）。Codex 並沒有對等的環境變數。

**修正建議**：
- 在 §Packaging and Distribution Plan 補一節「Codex skill 環境變數契約」，說明 `PR_REVIEW_TOOLKIT_ROOT` 由誰定義（install-time substitution？shell init？絕對路徑？），以及預期值。
- 或重用既有變數 `CLAUDE_PLUGIN_ROOT`，雖然語意不準但相容。
- 若 Codex skill 採 thin wrapper 委派根 `scripts/` 的策略（line 293），那 wrapper 內可寫死相對路徑，metadata 範例就不需要 `PR_REVIEW_TOOLKIT_ROOT` 了；建議擇一風格、全文一致。

---

## 重要（Should-fix before implementation）

### 5. `created_by` 與 `skill` 欄位語意重疊

§Shared Metadata Schema 範例同時有：

```json
"skill": "pr-review-and-document",
"created_by": "codex-review-pass",
```

文件說 `skill` 是「給舊版 parser 用」(line 97)，但這個 example 是 Codex bootstrap 場景—— 整份 comment 由 Codex 創建，把 `skill` 寫成 `pr-review-and-document` 反而是錯的。

**修正建議**：
- 明確 `skill` 與 `created_by` 的 lifecycle：建議 `skill` 改為「最後一次寫入此 comment 的 skill」（updated_by），`created_by` 維持「第一次建立此 comment 的 skill」。
- 或 deprecated `skill` 欄位，以 `last_writer` + `created_by` 取代，並在 migration 表格內列入。

### 6. Codex finding stable ID 設計脆弱

§Append Mode step 3 (line 180) 提議 `codex:<file>:<line>:<title-slug>` 作為穩定 ID。

問題：
- **行號漂移**：fix 一個 issue 後，後面所有 issue 行號改變，下一輪 Codex review 產生的 ID 全部不同 → dedup 失效 → 重複插入。
- **`title-slug` 不穩定**：Codex 兩次跑同一份 PR，自然語言摘要可能微幅差異。
- **多個 issue 同一行**：`<file>:<line>` 會碰撞。

**修正建議**：
- 改用「relative location」而非絕對行號（例如 `<file>:<symbol-name>:<diagnostic-kind>`），或加上代碼片段內容雜湊。
- 文件至少要明寫「ID 穩定性是 best-effort，無法保證跨輪去重 100%」，並說明使用者該怎麼處理重複。

### 7. `integrated_ids` 在 Gemini 與 Codex 之間語意不同

- `gemini-review-integrator/SKILL.md:138-145`：`gemini_integrated_ids` 是**外部 GitHub comment numeric ID**，用來防止重複消費同一個外部評論。
- §Shared Metadata Schema（line 91）：`review_sources.codex.integrated_ids` 是 **Codex 自己產出的 finding ID**（如 `codex:src/foo.ts:42:...`）。

兩者用同一個 key 但語意完全不同。一個是「我已經吸收了哪些**外部**訊息」，另一個是「我已經寫進 comment 的**自己**輸出」。

**修正建議**：
- 改名以反映語意：`gemini.consumed_comment_ids` vs `codex.posted_finding_ids`。
- 或維持 `integrated_ids` 但在 schema 文件加註腳，明寫 ID 來源差異。

### 8. 工作流缺少 commit 步驟

§Cross-Tool Workflow（line 237–266）描述的 flow 列出 Codex `codex-fix-worker` 修改檔案，但 §codex-fix-worker（line 230）規定 Codex 不可 commit / push / merge。

文件沒有任何地方說明：**Codex 修改完之後，誰來 commit 這些變更？** 預期是 dev agent，但 flow 圖完全沒有畫出。實作時很容易漏：dev agent 跑完 Codex 後沒有 commit，下一輪 Claude review 會把未 commit 的修改當成「workdir noise」來 review。

**修正建議**：
- 在 Cross-Tool Workflow 三個 flow 內每個 fix 步驟後加一行「dev agent commits」(or 人類 commits)。
- 在 §codex-fix-worker 補一個 output contract：fix-worker 輸出「modified files list + 一段 commit message draft」，方便 dev agent 接手。

---

## 次要（Nice-to-have / 文字小修）

### 9. Schema version 命名衝突

兩個 `schema_version: "1.0"` 同時存在於系統中：
- **Cache envelope** schema（`scripts/cache-read-comment.sh:95-114`）：`schema_version: "1.0"`，wrapper 結構。
- **Comment metadata** schema（`skills/pr-review-and-document/SKILL.md:80-96`）：`schema_version: "1.0"`，HTML comment 內 JSON。

文件 §Shared Metadata Schema 只 bump 後者到 1.1，但因為兩個欄位同名，閱讀文件容易誤以為前者也要動。

**修正建議**：
- 在文件最頂部「Single Source of Truth」一節，明確區分 *cache envelope schema*（保持 1.0、由 scripts 擁有）與 *comment metadata schema*（升 1.1、由 skills 擁有）。
- 考慮把 comment 內的欄位改名為 `metadata_schema_version` 以杜絕混淆（可作為 future work，1.1 暫不需要）。

### 10. Source tag 不一致

- Gemini：title 前綴 `[Gemini]`，內文 `**Source:** Gemini Code Assist`。
- Codex：title 前綴 `[Codex]`，內文 `**Source:** Codex`。
- Claude：**沒有** `[Claude]` 前綴（見 `skills/pr-review-and-document/SKILL.md:121-130`）。

`pr-review-resolver` Phase 3 要被升級成「recognize `[Codex]` issues as first-class」，但若 Claude issues 沒有 tag，resolver 沒辦法用「有沒有 `[Source]` prefix」來分流，只能用「沒前綴 → Claude」的隱性規則。

**修正建議**：
- 在 §codex-review-pass 增加註腳：「未 tag 的 issue 視同 Claude」是文件約定，Phase 3 升級時必須在 resolver SKILL 中明寫此規則。
- （可選）將 Claude 也改為 `[Claude]` 前綴，三來源完全對稱；這屬於 breaking change，需另案評估。

### 11. Bootstrap race window

`scripts/find-review-comment.sh:53-66` 對 `<!-- pr-review-metadata` 取所有 match，多筆時 warn + `head -1`。文件 §Bootstrap Mode 透過 `cache-read-comment.sh` exit 2 判斷 bootstrap，但兩個 tool 同時 bootstrap 會建立兩個 PR comment，後續 `find-review-comment.sh` 只會穩定指向其中一個。

實務上幾乎不會發生（dev agent 通常序列化呼叫），但應該在文件裡明寫：

> Bootstrap 階段須由 dev agent 確保不會並行觸發。若已存在 review comment，後到的 bootstrap 必須降級為 append。`cache-read-comment.sh` 已自動處理此情況（cache miss 時會打 GitHub API）。

### 12. Packaging：marketplace.json 對齊

`AGENTS.md` 規定 `plugin.json` 與 `marketplace.json` 版本必須同步，§Packaging and Distribution Plan（line 297）只提 `plugin.json`。Phase 4 的 release validation 應同時驗證 `marketplace.json` 與未來的 Codex metadata。

### 13. Phase 1 自我矛盾（小）

§Implementation Phases 的 Phase 1 寫「Add this design document」(line 310)。本份 review 對應的就是 Phase 1 的 review hop，建議文件落地時把 Phase 1 標題改為 `Phase 0: Design & review`，留 Phase 1 作為「執行 design 結論的 follow-up doc 修訂」，比較符合實際執行順序。

---

## 已驗證為正確的設計點

下列描述與 codebase 實際行為一致，無需修正：

- §Single Source of Truth：cache 路徑、wrapper 結構（驗證對照 `scripts/cache-read-comment.sh:94-114`、`scripts/cache-write-comment.sh:202-222`）✓
- §codex-review-pass Bootstrap mode 用 `cache-read-comment.sh` exit code 2 判斷 cache miss（驗證 `scripts/cache-read-comment.sh:65, 124`）✓
- 強調禁止建立第二個 review comment、禁止 Codex commit/push/merge ✓
- bootstrap 範例正確包含 `<!-- pr-review-metadata` marker（`scripts/upsert-review-comment.sh:50-52, 79-81` 對此有強制檢查）✓
- 沿用既有 marker（保證 `find-review-comment.sh` 可定位）✓
- 用 thin wrapper 委派根 `scripts/` 而非複製（line 293）✓
- 指名「`pr-review-resolver` 應認得 `[Codex]` issues」(line 324)：方向正確，需與第 10 點一起設計 ✓

---

## 上線前 checklist 建議

實作 Phase 2 / 3 前，請文件作者補完以下：

1. [x] §Shared Metadata Schema 加 1.0 → 1.1 migration table（涵蓋 `agents_run`、`gemini_integrated_ids`、`gemini_integration_date`）
2. [x] §Implementation Phases 把 Phase 2 與 Phase 3 合併為單一 release，或顯式寫「Phase 2 在 Phase 3 上線前不啟用」
3. [x] 並發策略決議：CAS（推薦）/ 檔案鎖 / 序列化約束，三選一並寫入文件
4. [x] 釐清 `${PR_REVIEW_TOOLKIT_ROOT}` 解析方式
5. [x] 釐清 `created_by` vs `skill` 的 lifecycle，或 deprecate `skill`
6. [x] Codex finding stable ID 演算法升級（或明寫限制）
7. [x] `integrated_ids` 改名以區分 consumed vs posted 語意
8. [x] Cross-Tool Workflow 補上 commit 步驟
9. [x] 區分 cache envelope schema vs comment metadata schema
10. [x] 釐清 Claude untagged issue 約定，並寫進 resolver Phase 3 工作項

---

# Round 2 Review

> Reviewed: 2026-04-30（同日二輪）
> Diff context: 對照 Round 1 後 codex 修訂版

## Round 1 項目驗收

逐條對照修訂後的文件：

| # | 項目 | 狀態 | 對應位置 |
|---|---|---|---|
| 1 | Phase ordering 風險 | ✅ 解決 | §Implementation Phases L423–432，Phase 2 明寫「must ship Claude compatibility updates and Codex skill scaffolding together」 |
| 2 | 1.0 → 1.1 migration table | ✅ 解決 | §Metadata Migration L130–138，明確列出每個 1.0 欄位的對應與規則，並聲明不支援 downgrade |
| 3 | 並行寫入保護 | ✅ 解決 | §Write Concurrency L71–83，列三個方案並推薦 CAS（`--expected-content-hash`、exit code 4）；Phase 1 任務也對齊 |
| 4 | `${PR_REVIEW_TOOLKIT_ROOT}` 解析 | ✅ 解決 | §Environment Contract L145–159，三層 fallback 並明禁用 `${CLAUDE_PLUGIN_ROOT}` |
| 5 | `created_by` / `skill` lifecycle | ✅ 解決 | L124：`created_by` = first creator、`last_writer` = last updater、`skill` = legacy（同步寫成 last_writer） |
| 6 | Finding ID 穩定性 | ✅ 解決 | §Finding ID L262–270，加入 `<symbol>:<diagnostic-kind>:<snippet-hash>`，並明寫「best-effort，不保證 100%」與重複處理策略 |
| 7 | Gemini/Codex 同名 ID 衝突 | ✅ 解決 | `gemini.consumed_comment_ids` vs `codex.posted_finding_ids` |
| 8 | Workflow 缺 commit 步驟 | ✅ 解決 | §Cross-Tool Workflow 三個 flow 都加上 `dev agent: commit fix-worker changes`，§codex-fix-worker L334 也補上 |
| 9 | 兩層 schema 命名衝突 | ✅ 解決 | §Single Source of Truth L33–36，明確區分 envelope vs comment metadata |
| 10 | Claude untagged issue 約定 | ✅ 解決 | L258 寫入 append mode；Phase 2 task list L429 明列「recognize `[Codex]` issues and untagged Claude issues」 |

10 項全部處理，整體品質提升明顯。

## Round 2 新發現

以下都是次要問題，不阻擋落地，但建議在 Phase 2 實作前補。

### R2-1. Append mode 沒寫 `review_round` 是否要 increment（Should-fix）

§codex-review-pass Append Mode L239–248 的步驟 7 列出要更新 `summary counts`、`updated_at`、`last_writer`、`review_sources.codex`，**沒提 `review_round`**。但既有 Claude SKILL（`skills/pr-review-and-document/SKILL.md:226`）規定 multi-round review 時要 increment `review_round`。

兩種合理解讀：

- **語意 A**：每個 reviewer 各自獨立計輪 → 應該在 `review_sources.codex` 內加 `review_round`（per-source）。
- **語意 B**：`review_round` 是 PR 整體的 review 輪次 → Codex append 時也要 increment，與 Claude 共用。

文件目前兩種都不是；不寫清楚會導致三個 skill（Claude/Gemini/Codex）對 `review_round` 行為不一致。

**建議**：在 §Shared Metadata Schema 加一段 `review_round` 語意說明，並在 append mode 步驟列補上對應動作。同時讓 §codex-fix-worker 明示「不 increment review_round」（fix-worker 不算一輪 review）。

### R2-2. Bootstrap 場景下 `skill` 欄位的值未被規範（Minor）

Bootstrap 範例 L196 寫：

```json
"created_by": "codex-review-pass",
"last_writer": "codex-review-pass",
"skill": "codex-review-pass",
```

但 Migration Table L133 只規範「升級既有 1.0 comment 時 `skill` 保留 legacy」，**沒規範 bootstrap（沒有 legacy 值可保留時） `skill` 該寫什麼**。實作者只能從範例倒推「bootstrap 時 skill = last_writer」。

**建議**：在 L124 lifecycle 段落明寫：

> Bootstrap 時 `skill` = `last_writer`（與 `created_by` 相同）；append/upgrade 時 `skill` 保留既有 legacy 值，不變更。

這條規則一行即可，但漏了會讓不同 producer 的實作互相矛盾。

### R2-3. Phase 1 沒給 CAS 的 firm commitment（Should-fix）

§Phase 1 Contract Safety L417–421 寫：

> Add compare-and-swap support to `cache-write-comment.sh --stdin`, **or** explicitly enforce dev-agent write serialization

「or」放在這裡有風險：如果 Phase 1 只挑序列化路線，CAS 永遠拿不到優先級，但 §Write Concurrency L81 又說「正式實作應優先加入 compare-and-swap」。Phase 1 與 §Write Concurrency 對 CAS 的態度不一致。

**建議**：Phase 1 改寫為：

> 必做：CAS 或序列化擇一上線。
> 若選序列化路線，須在 CHANGELOG / TODO 內登記 CAS 為後續版本必做（例如 Phase 1.5 或 Phase 4），不可無限延後。

避免「序列化先上、CAS 永遠『下次』」的常見技術債陷阱。

### R2-4. Append mode `EXIT_CODE=$?` 雖正確但脆弱（Nit）

L173–186 的 bootstrap 偵測：

```bash
if REVIEW_CONTENT=$(...); then
  MODE="append"
else
  EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 2 ]; then
    MODE="bootstrap"
  else
    exit "$EXIT_CODE"
  fi
fi
```

當前寫法 `EXIT_CODE=$?` 是 else 區塊第一句，正確。但這種 pattern 對未來編輯極為脆弱：任何人在 `else` 區塊與 `EXIT_CODE=$?` 之間插入一句 echo / log（例如 debug 輸出），$? 就會被覆寫成新的 exit code。

**建議**（可選，價值小）：用更穩固的寫法，例如：

```bash
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

或在 SKILL.md 的範例附註「請保持 `EXIT_CODE=$?` 緊貼 else 開頭」。如果 codex 實作會直接 copy 範例，這條值得加註腳。

### R2-5. `agents_run` 過渡期含糊（Minor）

Migration Table L134：

> 搬移到 Claude source；**可同時保留 top-level 一個 release 作為過渡**

「一個 release」沒對齊版本號或 phase。等實作時誰會記得在哪個 release 拿掉 top-level？

**建議**：把過渡視窗綁定到具體 phase。例如：

> Phase 2 寫入時同時在 top-level 與 `review_sources.claude.agents_run` 各保留一份（read 時優先 nested）；Phase 3 release notes 必須顯式列出 top-level `agents_run` 移除。

### R2-6. Bootstrap 期間多 tool race 的最終結果不可逆（Minor）

§Write Concurrency L83 說：

> Bootstrap 階段也必須序列化…後到者應重新執行 `cache-read-comment.sh`，若 comment 已存在則降級為 append mode。

但沒說「同時 race 真的發生時，已被誤建立的第二個 comment 怎麼處理」。`find-review-comment.sh:53-66` 只是 `head -1`，多餘的 comment 會永久殘留在 PR 上但被忽略。

**建議**：補一段 recovery procedure，例如：

> 若偵測到 PR 上有 >1 個 `<!-- pr-review-metadata` comment，dev agent 必須手動刪除多餘者，僅保留 `cache` 指向的那一個。

或在 `find-review-comment.sh` 改為對多 match 直接 fail 而非 warn，把這個錯誤推到設計時就被發現。

### R2-7. 「Reviewer Sources:」UI 字串未規範（Nit）

Bootstrap 範例 L212：

```markdown
**Reviewer Sources:** Codex
```

當 PR 同時有 Claude/Gemini/Codex 時，這行該怎麼寫？沒規範。寫法不一致會讓 UI 看起來零散。

**建議**：在 §Shared Metadata Schema 後加一行 derived field 約定：

> `Reviewer Sources` 行依 `review_sources` 中 `last_reviewed_at != null` 的 source 排序組合，例：`Claude, Gemini, Codex`。

同樣很小，但實作三套 skill 各寫各的就會分歧。

## Round 2 結論

- **Round 1 全部 10 項已落地**；文件品質從「需要結構性補強」升級為「可進入實作」。
- **R2-1（review_round 語意）與 R2-3（Phase 1 對 CAS 的承諾）建議在開 Phase 1 PR 前先補**，因為這兩條會直接影響 Phase 1/2 的 acceptance criteria。
- **R2-2、R2-5、R2-7 可在 Phase 2 SKILL 撰寫時順手釐清**，文件不一定要動。
- **R2-4、R2-6 是技術債級別的小防線**，不阻擋上線。

## Round 2 補充 checklist

- [x] R2-1：明示 `review_round` 是 per-source 還是 PR-global，並在 append mode 步驟列補上對應動作
- [x] R2-2：補上 bootstrap 場景的 `skill` 欄位寫入規則
- [x] R2-3：Phase 1 對 CAS 給出明確 commitment（直接做、或登記為下個 phase 必做）
- [x] R2-4（選做）：bootstrap 偵測範例改為 `set +e` / `case` 寫法，或加防呆註腳
- [x] R2-5：top-level `agents_run` 過渡期綁定到具體 phase
- [x] R2-6：補多 review comment 的 recovery procedure
- [x] R2-7（選做）：規範 `Reviewer Sources:` UI 行的生成規則

---

# Author Response

> Responded: 2026-05-05  
> Response target: Round 2 review items in this file  
> Updated design: `docs/codex-integration-design.md`

感謝二輪 review。Round 2 的 7 個補充點都合理，已全部接受並回寫到設計文件。以下是逐項回覆。

## R2-1 review_round 語意

**Accepted.** 已明確定義 `review_round` 是 PR-global review producer 輪次，不是 per-source 輪次。

設計決策：

- `pr-review-and-document` 與 `codex-review-pass` 產生新 review pass 時 increment。
- `gemini-review-integrator` 只整合外部 comment，不 increment。
- `codex-fix-worker` 與 `pr-review-resolver` 只修復或更新狀態，不 increment。

已同步更新 `codex-review-pass` append mode 與 `codex-fix-worker` workflow。

## R2-2 bootstrap skill 欄位

**Accepted.** 已補上 lifecycle 規則。

設計決策：

- Bootstrap 時 `skill = last_writer = created_by`。
- Append / upgrade 既有 1.0 comment 時，`skill` 可保留舊值一個過渡 release。
- 新版邏輯仍以 `last_writer` 與 `review_sources` 為準。

## R2-3 CAS commitment

**Accepted.** 已把 Phase 1 改成更明確的 contract safety gate。

設計決策：

- Phase 1 必須上 CAS 或明確序列化其中一種保護。
- 若先採序列化，必須在 `CHANGELOG.md` 或 tracked TODO 登記 CAS 為後續必做。
- 不允許把 CAS 永久留在「下次再做」狀態。

## R2-4 bootstrap detection robustness

**Accepted.** 已把範例改成 `set +e` / `case` 寫法，避免 `EXIT_CODE=$?` 被未來插入的 log 覆蓋。

## R2-5 agents_run 過渡期

**Accepted.** 已把過渡期綁定到 Phase 2。

設計決策：

- Phase 2 寫入時 top-level `agents_run` 與 `review_sources.claude.agents_run` 同時保留。
- Read 時優先 nested。
- 移除 top-level `agents_run` 必須另開 release，並在 release notes 明確列出。

## R2-6 duplicate bootstrap recovery

**Accepted.** 已補上 recovery procedure。

設計決策：

- 若 PR 上存在多個 `<!-- pr-review-metadata` comments，dev agent 必須只保留 `.pr-review-cache/pr-#.json` 的 `source_comment_id` 指向的 canonical comment。
- 其他重複 comments 應刪除或標記為非 canonical。
- 長期可考慮讓 `find-review-comment.sh` 多 match 時 fail，而不是 warn 後取第一筆。

## R2-7 Reviewer Sources UI

**Accepted.** 已規範 derived field。

設計決策：

- `Reviewer Sources` 依固定順序輸出：`Claude, Gemini, Codex`。
- Claude / Codex 以 `last_reviewed_at != null` 判斷是否參與。
- Gemini 以 `last_integrated_at != null` 或 `consumed_comment_ids` 非空判斷是否參與。

## Follow-up

設計文件目前已可作為 Phase 1 實作輸入。下一個 PR 應優先處理 contract safety，特別是 `cache-write-comment.sh --stdin` 的 CAS 或明確序列化策略，避免 Codex skills 上線後發生跨 tool 覆蓋。

---

# Round 3 Review

> Reviewed: 2026-05-05（依文件 metadata；如為 fold 後重審請更新）
> 對照 Author Response 後實際進入 design doc 的修改

## R2 項目落地驗收

逐條對照修訂版實際內容（行號為 design doc 最新版）：

| # | 項目 | 落地位置 | 結果 |
|---|---|---|---|
| R2-1 | review_round 是 PR-global 還是 per-source | L128 prose、L253 append step 7、L305 fix-worker step 7 | ✅ 三處同向，PR-global、producer 才 increment |
| R2-2 | Bootstrap 場景 `skill` 寫入規則 | L126 lifecycle 段尾 | ✅ 明寫「bootstrap 時 `skill = last_writer`」 |
| R2-3 | Phase 1 對 CAS 的 commitment | §Write Concurrency L81、§Phase 1 L427–428 | ✅ 強制「若先採序列化必須登記 CAS 為後續必做」 |
| R2-4 | Bootstrap 偵測 `EXIT_CODE=$?` 脆弱 | L182–191 | ✅ 改為 `set +e` / `case` |
| R2-5 | `agents_run` 過渡期含糊 | Migration Table L140 | ✅ 綁定 Phase 2 寫雙份、移除須 release notes |
| R2-6 | 多 PR comment recovery | §Write Concurrency L85 | ✅ 補手動 recovery + 長期 fail-fast 提案 |
| R2-7 | `Reviewer Sources` UI 規則 | L130 | ✅ 固定順序 `Claude, Gemini, Codex` + 派生條件 |

**Round 2 全部 7 項實際進入設計文件，不只在 review 註記中**。

## Round 3 新發現

兩項都屬於 nit / 風格層級，不阻擋落地。

### R3-1. 「無新發現的 review pass」是否 increment `review_round`（Minor）

L253（append mode step 7）寫：

> increment PR-global `review_round`

但同一節 L267 又寫：

> 若沒有新發現，仍可更新 `last_reviewed_head` 與 `last_reviewed_at`，但不應改動既有 issue 狀態。

兩條文未明確互動。字面解讀：

- 步驟 7 是「append mode 必走」步驟之一 → 即使沒有新 finding 也 increment。
- 但 round 通常代表「有實質內容變動的一輪」；連跑 5 次空 pass 就變第 5 輪，與直覺不符。

**建議**：在 L253 加一句 qualifier，例如：

> 7. 若有新增 finding，increment PR-global `review_round`；若整輪沒有新發現，僅執行 L267 的 `last_reviewed_head` / `last_reviewed_at` 更新，不 increment

或直接在 L267 補上「不 increment review_round」呼應 fix-worker 的寫法。

### R3-2. fix-worker 工作流中的 negative step（Style nit）

`codex-fix-worker` 工作流現為 9 步：

```
...
6. 將該 issue 狀態改為 ✅
7. 不 increment `review_round`
8. 使用 cache-write-comment.sh --stdin 寫回
9. 回報 ...
```

step 7 是 negative step（規定不做某事），放在 numbered list 中略顯不自然，且容易在實作時被忽略（「不做的事」本來就不會出現在 code path）。

**建議**（可選）：

- 把「不 increment `review_round`」搬到 §codex-fix-worker 「不可以」列表（L315–321），與其他禁止項並列。
- 或改寫成 affirmative：「step 7. 保持既有 `review_round` 不變」。

風格選擇，不影響正確性。

## Round 3 結論

- 設計文件結構完整、契約明確、relative concerns 都已成文，**正式可作為 Phase 1 PR 的輸入**。
- R3-1 的「空 pass 是否 increment review_round」應在 Phase 2 寫 SKILL 時釐清，否則會由實作者各自決定，下一次 review 又得繞回來。
- R3-2 屬於可動可不動的編輯偏好，不阻擋。

設計階段可以視為收斂；後續 review 應改為對 Phase 1 / Phase 2 PR 進行 implementation review，而不是再 round 設計文件本身。

---

# Author Response — Round 3

> Responded: 2026-05-05  
> Updated design: `docs/codex-integration-design.md`

Round 3 兩個 nit 都接受，因為改動小且能避免 Phase 2 實作者自行解讀。

## R3-1 空 review pass 是否 increment review_round

**Accepted.** 已明確規範：

- 只有含有新增 findings 的 `pr-review-and-document` / `codex-review-pass` 才 increment PR-global `review_round`。
- 空 review pass 只更新 `last_reviewed_head` / `last_reviewed_at`，不 increment。

## R3-2 fix-worker negative step

**Accepted.** 已將 `codex-fix-worker` workflow 中的 negative step 改成 affirmative wording：

> 保持既有 `review_round` 不變

這比「不 increment」更適合放在 numbered workflow 內。

## Final Position

設計文件目前已收斂。後續應進入 Phase 1 contract safety implementation review，不再延長 design-only review loop。
