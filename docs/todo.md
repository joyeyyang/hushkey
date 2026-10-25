# 待辦與現況

每一項都寫「怎麼驗的」，沒驗過的不標完成。

## 1. 輔助使用權限：開關是開的，App 卻說沒有（2026-10-25）

**症狀**：系統設定裡 `OfflineVoiceAssistant` 的開關看起來是開的，
App 仍然顯示「尚未取得輔助使用權限」、貼不出去。

**實際原因（已查證）**：使用者的 TCC 資料庫裡**沒有**
這支 App 的 `kTCCServiceAccessibility` 紀錄，只有麥克風、行事曆、
文件夾。也就是那條「開著的列」不是這支程式。

```
$ sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
    "select service, client, auth_value from access where client like '%com.example%'"
kTCCServiceSystemPolicyDocumentsFolder|com.example.offlinevoiceassistant|2
kTCCServiceMicrophone|com.example.offlinevoiceassistant|2
kTCCServiceCalendar|com.example.offlinevoiceassistant|2
```

授權綁在程式簽章上。每次重打包換掉 `/Applications` 裡的 App，舊紀錄就
對不上執行中的二進位檔，而系統設定不會把那一列自動收掉——就成了
「開關開著、API 說沒有」的死結，而且那個開關按不掉也重開不了。

補充（01:00 查到的時序）：00:28 時資料庫確實沒有輔助使用列，App 也回報未授權；
00:59:33 從 `dist/` 啟動時卻回報 `trusted=true`，代表那時已經有一筆對得上的授權。
也就是「時好時壞」不是偵測程式有問題，是授權紀錄與當下執行的那份 bundle
對得上或對不上。這批修正把「對不上」的情況變成使用者按一下就能清掉。

**已做**：

- `TextInjector.resetAccessibility()`：跑 `tccutil reset Accessibility <bundle id>`，
  把對不上的舊紀錄清掉。系統設定裡「重設權限（清掉舊紀錄）」按鈕就是它。
- `TextInjector.identity`：`ova.log` 現在會寫出「哪一個 bundle、bundle id、
  當下判定」，下次再發生可以直接看出是不是拿到別的副本。
- 重設後立刻重新呼叫 `AXIsProcessTrustedWithOptions(prompt: true)`，
  這是唯一會讓 App 用「現在的簽章」重新出現在清單裡的正規做法。
- 打包腳本簽完章後跑 `lsregister -f`，避免 LaunchServices 留著舊的 bundle 紀錄。
- 既有的 2 秒輪詢 + 回到前景時重查照舊，授權一到手橫幅會自己消失，不必重開 App。
- 實測 `tccutil reset` 回了 3 次 `Successfully reset`（代表先前真的有 3 筆
  對不上的紀錄），清完後資料庫已無輔助使用列。

**目前狀態**：舊紀錄已清空（`tccutil reset` 回了 3 次成功），資料庫現在沒有
輔助使用列，App 顯示未授權——這是預期中的乾淨起點。

**還要你做一次**：App 開著 → 按橫幅上的「重設權限（清掉舊紀錄）」（或直接用
啟動時跳出的系統對話框）→
系統跳出的對話框按「打開系統設定」→ 在輔助使用清單用「＋」加入
`/Applications/OfflineVoiceAssistant.app` 並打開開關 → 回 App，橫幅應該
在 2 秒內自己消失。

**驗證方式**：`ova.log` 出現 `accessibility trusted: true`，且
`tccutil reset` 之後資料庫出現 `kTCCServiceAccessibility|com.example.offlinevoiceassistant|2`。

## 2. 模型管理器（已完成，待目視）

`ModelManagerView` 接進主視窗「模型」分頁：列出每一列 manifest、
已安裝/未安裝、下載進度（速度與剩餘時間）、刪除（會確認，且不給刪正在用的）、
LLM 切換、標頭顯示目前載入的 ASR 與峰值記憶體。

驗證：`OVC_SELFTEST_MODELS=/tmp/ovc-models` 會把「模型」分頁離屏畫成 PNG。

## 3. 匯入音檔（已完成，已驗）

「匯入音檔…」按鈕（或把檔案拖到「轉錄」分頁背景）走同一條引擎管線；
解碼失敗/引擎忙碌會自動重試 3 次，永久性錯誤不重試。結果不自動貼上，
只放進逐字稿視窗與剪貼簿。

驗證：

```
OVC_SELFTEST_IMPORT=<clip>.wav dist/OfflineVoiceAssistant.app/Contents/MacOS/OfflineVoiceAssistant
→ audio import: done 0.wav segments=1 seconds=5.4
→ import done: 29 chars, 1 segments
```

## 4. 翻譯預設（已完成）

聽寫預設 `auto`：整理時就用繁體中文輸出；如果使用者在這段話裡明確要求
換語言（「整理成英文」），整理步驟照辦，並把那句指令本身從結果裡去掉。
`translateIfNeeded` 在 `auto` 模式不做第二次翻譯，否則會把英文答案再翻回中文。

連帶修掉一個會擋掉正確結果的檢查：`sanityCheck` 原本規定「原文有中文，
結果就必須有中文」，現在只有在原文真的指名另一種語言時才放行無中文的結果。

驗證：待補真實錄音（需要麥克風與輔助使用）。

## 5. 檔名一致性（已完成）

會議自動存檔與之後的匯出原本各用一套命名，同一場會議會在資料夾裡出現
兩個名字。現在共用 `Naming.stem(title:date:)`，而且日曆事件優先於摘要第一行
——會讀行事曆就是為了讓檔案叫「週五產品會議」。

## 6. 介面重做（2026-10-25，進行中）

原本的視窗只是「同一個系統預設介面換底色」：米色視窗 + 系統 bezel 按鈕 + 系統
分頁列。主題只改了底色和外觀，所以看起來跟改版前一樣。這次改成一套自己的
視覺語言（`DesignKit.swift`）：

- **標題列**：透明 titlebar，視窗自己畫名字、一行意圖說明、右邊狀態膠囊
  （顏色代表 就緒／載入中／失敗，不用讀字）。
- **分頁**：不用 `NSTabView` 的分頁列，改成自己畫的 pill 列；選中的那顆用
  `accentQuiet` 底色 + accent 字。
- **卡片**：所有內容放在 `ThemeCard`（surface 底、1px hairline 邊、圓角 10），
  不再用 bezel scroll view。
- **按鈕**：primary（accent 實心、字色由亮度算出）／secondary（描邊）／
  ghost（文字）／danger，有 hover 態。錄音那一列是唯一的大按鈕。
- **逐字稿**：卡片內 13 pt、行高 1.32，內距 14/12。
- **權限橫幅**：warning 淡底卡片，三顆按鈕（開啟設定／我已經開好了／重設權限）。

分頁內容另外拆成獨立檔：`HistoryTabView.swift`、`SettingsTabView.swift`
（由 subagent 產出，主代理負責接線與編譯修正）。

驗證：`OVC_SELFTEST_UI=/tmp/ovc-ui OVC_SELFTEST_UI_THEME=paper,night` 會把
五個分頁、整個視窗、浮動逐字稿各離屏畫成 PNG（沒有視窗伺服器也能看）。
已用 paper／night／slate／moss／clay 五套主題看過，卡片、分頁 pill、停用態
按鈕、狀態膠囊都正常。commit `79340b2`。

**逐字稿可直接複製（2026-10-25）**：結果卡片右上角有「複製」鈕（沒有結果時
停用），按下去把整段文字放進剪貼簿並在狀態列顯示「已複製逐字稿」；文字本身
可選取，Cmd+C 也能用。浮動逐字稿視窗的標題列同樣有一顆「複製」，複製的是
目前畫面上看到的原文，不必再回歷史分頁。這樣即使沒有輔助使用權限（無法自動
貼上），也能用 Cmd+V 自己貼。

## 6.5 AI 整理的三個缺陷（2026-10-25）

使用者回報三件事，都在整理階段（`core_engine/src/llm.rs`）：

1. **口頭指令沒被執行。** 講「把前面那句刪掉」「第二點不要」，結果裡那句還在。
2. **語言被翻走又沒翻回。** 中文問句裡夾了英文產品名，整段變成英文。
3. **結尾多餘的句號。**

**修的辦法（範例優先，規則其次）：**

- `REFINE_SYSTEM` 收緊語言規則：**講什麼語言就寫什麼語言**，句中有英文產品名照留、
  問句也一樣；只有明確要求翻譯時才換語言，而且要整段都換。原本的寫法
  「明確要求換成別的語言」是破口——一句夾英文的中文問句會被讀成這種要求。
- `REFINE_EXAMPLES_ZH` 由 2 組加到 5 組，加了「刪除」與「替換」的示範
  （`下週三下午三點半開會，地點在二樓會議室，把地點那句刪掉…` → `下週三下午三點半開會，地點還沒確定`），
  以及一組「整句中文夾英文產品名，維持中文」。英文範例同步補刪除／替換，並把
  四組舊答案結尾的句號拿掉，讓規則和示範一致。
- **翻譯改成兩段確定性流程**：`detect_translation_request` 先在輸入裡找翻譯指令
  （`翻成英文`／`翻成中文`／`translate into english`…，弱的說法如「用英文」還要
  旁邊有「請／幫／把／這句／整理／回答」才算指令，避免把「我用英文寫了一封信」
  誤判），把指令那段從草稿裡切掉，先**用原語言整理**，再**用同一顆已載入的模型**
  翻譯（`translate_in`，只多一次生成、不多一次載入；日韓文不在 `translate_prompt`
  的支援範圍，維持交給模型）。這樣 2B 模型不必自己判斷要不要換語言。
- **格式由程式強制**：`tidy_output` = 去外框引號 → 單行答案去掉項目符號
  （`• 下週三開會` → `下週三開會`，兩行以上的清單保留）→ 折疊 3 行以上空白 →
  **只砍最後一個** `。`／`.`／`．`（`…`、`？`、`！`、`：`、`；` 和句中的句號不動）。
  摘要輸出不走這一段（摘要是一份文件，項目符號本來就可能以句號結尾）。

**實測**（`Qwen3.5-2B-Q4_K_M`，`ovc-llm-worker refine`）：

| 輸入 | 輸出 |
|---|---|
| 先確認規格。再去找供應商。把前面那句刪掉 | 再去找供應商 |
| 第一，確認規格。第二，找供應商。第三，排時程。第二點不要 | 第一，確認規格。第二，排時程 |
| 呃就是那個，下週三…地點那句先刪掉，我還沒確定 | 下週三下午三點半開會，地點還沒確定 |
| 這個 API 的 rate limit 是多少？ | 這個 API 的 rate limit 是多少？ |
| 把這句翻成英文：明天下午三點跟客戶開會 | Meet with the client at 3 PM tomorrow afternoon |
| 明天下午三點開會。 | 明天下午三點開會 |

單元測試 52 項（含新增的 `strip_lone_bullet`、`detect_translation_request` 純函式測資）。

## 6.6 檢索輔助（EmbeddingGemma INT4）＋語音輸入打包（2026-10-25）

### 模型
`rag-embeddinggemma-300m-q4`：`embedding/embeddinggemma-300m-Q4_0.gguf`，277,852,192 bytes，
sha256 `edc6015cb15694c27be7d1d33f1bc015db9a358ff51ed524628c027504907ba9`。
這是 **QAT（量化感知訓練）的 Q4_0**，不是普通 Q4：MTEB 多語言平均 60.62 對 Q8 的 60.93
（差 0.31），繁中檢索在 5 億參數以下的開源模型裡排名第一（DRCD Hit@5 94.96%）。
架構 `gemma-embedding`，768 維，2048 ctx，**Mean pooling**（不是 Last）。
上游 GGUF 少了 Sentence-Transformers 的 dense module，對本用途沒差：詞與逐字稿都用
同一顆模型算，排名自洽。

### 實測（`core_engine/examples/embed_probe.rs`，全部是真實繁中句子）
**詞彙檢索——排序可靠，門檻不可靠。** 草稿「明天下午三點要跟小林開會，討論隼的第四季
時程，Figma 的稿子我會先更新」：該抓到的 0.402–0.465（小林／隼／第四季／Figma），
不該抓到的 0.260–0.479（`小林設計` 0.479 甚至比 `小林` 0.465 高，因為它真的共用「小林」）。
→ 所以門檻只設 0.35 砍掉明顯無關的尾巴，真正的價值在**排序**與 top-12，不做硬切。

**指令篩選——單一相似度門檻做不到。** 兩次量測間隙都是負的：一般說話
`順序是這樣沒錯` 0.783 ＞ 真指令 `第二點不要` 0.765；`他說時間會改` 0.648、
`我要加薪` 0.628。短句中文 embedding 的相似度主要反映語氣與虛詞，不是意圖。
→ 改成**「關鍵字必須命中」＋「相似度 0.65 確認」**：關鍵字表決定召回（可擴充），
門檻決定精確度（寧漏不錯殺，因為漏掉的指令整理提示詞本身還是會照做）。
保留樣本（未放進範例表的真指令）靠這條規則通過 4/4，帶關鍵字的一般說話誤判 0 筆。

**ASR 沒有標點，這是第一版真正的破口。** 實機聽寫整段是一個超長子句，被長度上限丟掉，
篩選等於完全沒作用（而手寫測試全過）。改成在關鍵字附近取 24 字內的**視窗**；而視窗
**只算分、不注入**——實測把 `季時程把地點那句拿掉我還沒確定另外稿我會` 這種錯位片段
餵給模型，它會認不出來並把指令留成內容；只有完整的短句才引用給模型。

### 架構
- `core_engine/src/embed.rs`：載入、Mean pooling 向量、L2 正規化、詞向量磁碟快取
  （`models/.cache/term-vectors.tsv`，含範例向量，以 model 檔名＋維度驗證；範例用
  `\u{1}` 命名空間與詞彙分開，因為兩者前綴不同）、關鍵字排序、指令篩選、視窗切句。
- `core_engine/src/state.rs`：`screened_hint()` 在整理前把提示詞換成「這次真的講到的詞」，
  並附上「使用者的修改要求（原話）」；`warm_retrieval()` 供主程式先算好向量。
- C ABI：`LLM_RelevantTerms`／`LLM_EditClauses`／`LLM_WarmRetrieval`（沒有模型時回空字串，
  不是錯誤）。`OVC_EMBED_DISABLE=1` 可停用，`OVC_EMBED_MODEL` 可換檔名。
- 設定頁新增「檢索輔助」開關（預設開，`settings.retrieval`）；模型管理頁多一個
  「檢索模型（向量）」分類。

### 效能（M1 8GB，實測）
- 冷快取取暖：29 個向量 2.9 秒；再取暖 0 個（快取有效）。
- 完整聽寫（ASR＋檢索＋LLM 整理）：**6.5–7.4 秒**，幾乎等於基準線（ASR＋LLM）7.5 秒，
  也就是檢索現在幾乎不用錢。
  對照：**檢索放在 App 行程時是 11.8–13.2 秒**，而且 `n_ctx` 從 2048 降到 256 完全沒差
  → 那 4–5 秒不是算向量、也不是 context 配置，是**記憶體壓力**（App 行程同時持有 ASR
  與 277 MB 向量模型，再開 1.2 GB 的 LLM 子行程）。
  **修法：把檢索搬進 worker 行程**（`state::screen_hint_for_worker`）——worker 先載入
  向量模型篩選、放掉它，再載入 LLM，高峰從「相加」變成「取大值」。
  過程中撞到一個真 bug：`embed` 與 `llm` 各自有一個 `OnceLock` 包住
  `LlamaBackend::init()`，以前兩者永遠在不同行程所以沒事，同一個行程就
  `BackendAlreadyInitialized` 讓整個 refine 失敗（退回原文）。改成共用 `llm::backend()`。
- `voiceinput --warm` 可在安裝後／啟動時先把向量算好，避開第一次的延遲。

### 語音輸入打包成可呼叫模組（使用者要求「放在另外一個資料夾」）
`macos_app/Sources/VoiceInputKit/`：獨立 target，含 `VoiceInputConfig`、
`VoiceInputEngine`（`prepare`／`transcribe(fileAt:)`／`makeSession`／`warmRetrievalCache`）、
`VoiceInputSession`（即時錄音）、`relevantTerms(for:in:)`、`editInstructions(in:config:)`、
`CursorInserter`（貼到游標）。另有命令列工具 `voiceinput`：
`--transcribe`／`--raw`／`--selftest`／`--warm`／`--keyword`／`--worker`。
**App 已經改用這個模組**：`OfflineVoiceAssistant` target 依賴 `VoiceInputKit`，
`AppController.polish()` 改成呼叫 `refineTranscript(_:config:)`，App 自己那份
「整理＋檢查＋翻譯」實作刪掉了（`translateIfNeeded` 移除），所以整理鏈只有一份實作，
App 與命令列工具不可能各自漂移。Kit 也已經有系統音訊能力（`VoiceInputKit/SystemAudioCapture.swift`，Core Audio process
tap、macOS 14.2+、與麥克風分開的權限），`VoiceInputConfig.captureSystemAudio` 打開後
逐字稿會自動分成麥克風（我）與系統音訊（對方）兩路，暫停時兩路一起停。
**App 的會議模式仍走原本自己的 tap**：會議要的是原始逐字稿＋摘要（不是整段潤飾），
而 `session.finish()` 會跑整理鏈，所以把會議搬過去需要一個「不潤飾」的 session 模式，
這件事沒做完，我沒有假裝它做完了。

### 錄音視窗合併（使用者要求「麥克風視窗與文字視窗合併」）
`HUDWindow` 改名 `DictationWindow`，`TranscriptWindow.swift` 刪除。現在語音輸入期間只有
**一個**浮動視窗：上方控制列（麥克風、波形、字數、暫停、停止、拖曳點），下方標題列
（狀態膠囊、複製、Esc 關閉）與逐字稿卡片（我：／對方：）。視窗由 56pt 長到 274pt，
逐字稿過長時自己捲動，錨定左上角所以停止鍵不會移動。Escape 仍然只關視窗、不停止錄音。

## 6.7 檢索模型整個移除（2026-10-25）

使用者實測後判定**輸出不可用**，要求刪掉。已完整移除，不是關掉：

- `core_engine/src/embed.rs`、`examples/embed_probe.rs` 刪除；`lib.rs`／`state.rs`／
  `llm.rs`／`bin/ovc-llm-worker.rs` 退回加入檢索之前的狀態（`git checkout e67bf1f^`），
  只保留 `OVC_LLM_WORKER`（讓命令列工具找得到 worker）。
- C ABI `LLM_RelevantTerms`／`LLM_EditClauses`／`LLM_WarmRetrieval` 與兩份 header 的宣告移除。
- Kit：`Retrieval.swift` 刪除、`CoreABI` 的檢索呼叫、`VoiceInputConfig.embedModel`／
  `embeddingModelURL`、`warmRetrievalCache()`、CLI 的 `--embed`／`--warm` 全部移除。
- App：設定頁的「檢索輔助」開關、模型管理頁的「檢索模型（向量）」分類、manifest 的
  `rag-embeddinggemma-300m-q4`、以及磁碟上的 265 MiB 模型與 `models/.cache/` 全部刪除。
- 單元測試從 68 回到 52（少掉的是 embed 模組自己的測試）。

**關鍵字提示也不再餵給模型**（使用者指示「讓 AI 模型自己去猜」）：`Refiner.polish` 送出空的
hint。理由寫在程式裡：清單裡有、但這次沒講到的名字會被模型拉進句子裡，這個失敗模式比
拼錯更糟。關鍵字分頁與清單先保留（沒有刪除），但目前不影響輸出。

**錄音時的兩個浮動視窗還原**（使用者澄清：要兩個視窗，只是不要重複的功能）：
`HUDWindow`（膠囊：麥克風、波形、字數、暫停、停止、拖曳點、以及過場訊息）與
`TranscriptWindow`（逐字稿：標題、狀態膠囊、複製、Esc）各自還原成獨立視窗，分工是
「膠囊＝控制與過場訊息」「逐字稿視窗＝文字、狀態、複製」。離屏自檢現在兩種視窗都畫。

## 7. 還沒做

- 語音編輯：實機驗證。
- ASR 準確度仍不如 macOS 內建聽寫（使用者回報 2026-10-25），
  待逐項檢查 VAD 邊界、語言提示、解碼方式與輸入增益。
- 長會議（>5 分鐘）的切段與去重尚未在真實錄音上跑過。
- 台語（Minnan）只驗過模型支援，沒有用真人錄音聽過。

## 8. ASR 退回 SenseVoice、浮動視窗合併、檢索移除確認、語音編輯（2026-10-25）

### 8.1 語音輸入結果不符 — ASR 退回 SenseVoice Small int8

**症狀**：使用者回報輸出跟講的完全對不上。

**證據（`history.json` 的 raw 欄位）**：10-25 06:22–08:22（舊建置，SenseVoice）可讀；
09:57 之後（重新打包後開始載入 Dolphin base int8）變成「说费三个。不敢干母亲一个专门的行为」，
甚至出現日文「手がちょっと」。

用 `say` 合成乾淨中文 A/B（同音訊、同機）：

- Dolphin：「明天下午三点跟小林开会。讨论第四季时乘地点还没。确定搞我会先更新。」
- SenseVoice：「明天下午3点跟小林开会，讨论第四季时辰地点还没确定搞我会先更新。」

兩者各錯一詞（時程）。結論：Dolphin 只贏在 99 MB／0.141 s（單一 5.6 秒片段），
**沒換到準確度**，預設改回 SenseVoice；Dolphin 仍安裝，`OVC_ASR_MODEL=dolphin` 可切回。

manifest 的 download 旗標同步交換（新安裝抓 SenseVoice int8＋tokens），
`scripts/verify_models.sh` 對新清單通過。`ova.log` 現在每次聽寫寫出 ASR 原文（`asr: …`，
160 字截斷），因為先前無法從日誌分辨是辨識錯還是整理錯。

### 8.2 兩個浮動視窗合併成一個

使用者第二次明確要求合併。作法：取回 `10ae502` 的合併版 `DictationWindow`、
刪除 `TranscriptWindow.swift`。單一視窗＝控制列（麥克風、波形、字數、暫停、停止、拖曳）
＋標題列（狀態膠囊、複製、Esc）＋逐字稿卡（我：／對方：）。Esc 只關視窗不停止錄音，
暫停仍是獨立功能。

注意：使用者當下跑的仍是舊建置，所以還看到兩個視窗（本節取代 6.7 的「兩個視窗還原」）。

### 8.3 檢索完全移除的確認

磁碟（`models/embedding/`、`models/.cache/`）、manifest、程式皆無殘留；
關鍵字維持「交給原本的 AI 模型自己判斷」，不注入提示。

### 8.4 語音編輯（`LLM_EditText`）

worker 新任務 `edit`：core 自己編號（多行或多句），提示詞要求保留原編號只改被指到的行，
程式依編號解析回來；沒有編號的回覆一律當失敗（聊天式回覆不能覆蓋使用者的文字）。
Kit 加 `isVoiceEditInstruction`／`applyVoiceEdit`；App 把指令套用到上次交付的文字，
再用 Accessibility 精準選取後貼上覆蓋，無法證明位置時只放剪貼簿＋提示。
**本節標明「尚未實機驗證」**。

**驗證**：`history.json` raw 欄位前後對照（06:22–08:22 vs 09:57 之後）＋`say` 同音訊
A/B（Dolphin／SenseVoice 各錯一詞）；manifest 新清單過 `scripts/verify_models.sh`；
檔案層面 `models/embedding/`、`models/.cache/`、`TranscriptWindow.swift`、
`core_engine/src/embed.rs` 皆已不存在；8.4 只有程式與提示詞，**尚未實機驗證**。
