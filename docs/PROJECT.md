# 專案總覽

> 對應 commit `747b3f8`。程式碼 18,590 行（Rust 3,9xx＋Swift 14,6xx）。
> 這份是入口文件；決策的來龍去脈在 `docs/todo.md`，選型在 `docs/model-choice.md`，
> iOS 版的階段與完成定義在 `docs/milestones.md`（M0–M6，附實測 log 與重跑指令）。

## 1. 這是什麼

macOS 選單列語音輸入 App。按 Option+Space → 說話 → 逐字稿貼到游標所在的地方。
完全離線：音訊與逐字稿不離開這台 Mac。

```
麥克風 ──▶ ASR (Rust+sherpa-onnx, Dolphin int8) ──▶ 逐字稿
                                                     │
                          ┌──────────────────────────┴────────────┐
                          ▼                                       ▼
              LLM worker (Rust+llama.cpp, Qwen3.5-2B)      貼到游標 (AX + CGEvent)
              整理 / 摘要 / 翻譯 / 語音編輯                    (或剪貼簿)
```

Rust 核心 + Swift App。Swift 部分可以只用 SwiftPM 建置，不需要開 Xcode。

## 2. 目錄結構

```
core_engine/            Rust 核心，純 C ABI
  src/lib.rs            ABI 進入點（extern "C"）
  src/state.rs          引擎狀態機：ASR 生命週期、LLM 呼叫、摘要分段
  src/llm.rs            llama.cpp 包裝：提示詞、生成、解析、語音編輯
  src/asr.rs  vad.rs  segmentation.rs  chunking.rs
  include/offline_voice_core.h    ← 這份是對外契約
  examples/             量測探針（asr_probe、edit_batch、section_probe、meeting_summary）

macos_app/              SwiftPM
  Sources/COfflineVoiceCore/include/  ← 同一份 header 的副本（必須同步）
  Sources/VoiceInputKit/   ★ 可重用函式庫：引擎、編輯、系統音訊、貼上
  Sources/OfflineVoiceAssistant/  App 本體（視窗、設定、模型管理）
  Sources/voiceinput/     CLI（voiceinput）

models/manifest.json    模型來源、大小、SHA-256
scripts/                build / verify / download / package / ax_check
docs/todo.md            ★ 決策紀錄（本報告的很多內容源自這裡）
```

## 3. 對外契約：Rust 核心的 C ABI

核心只透過 C ABI 對外。Swift 端只看得見 `offline_voice_core.h`。

```c
Core_Initialize(models_dir) / Core_Shutdown()
Core_GetLastError() / Core_FreeString(s)

ASR_Start / ASR_SubmitAudio / ASR_SubmitTagged / ASR_Peek / ASR_TakeSegments / ASR_Stop

LLM_RefineText            整理
LLM_RefineTextWithKeywords
LLM_RefineTextWithKeywordsStages   分兩段整理
LLM_Summarize             會議摘要
LLM_Translate             翻譯
LLM_EditText              ★ 語音編輯
```

規則：回傳的字串由呼叫端負責釋放（`Core_FreeString`）。每個進入點都在同一把全域
mutex 上序列化。錯誤碼是 ABI 的一部分。

`ASR_SubmitTagged` 的 `speaker` 參數：`1` = 系統音訊。

**兩份 header 必須同步**：`core_engine/include/` 與
`macos_app/Sources/COfflineVoiceCore/include/`。加符號要記得兩邊都加。

## 4. 三層架構與「誰負責什麼」

| 層 | 位置 | 職責 |
|---|---|---|
| 核心 | Rust | ASR、LLM、摘要分段、編輯的行定位。無 UI 概念 |
| Kit | Swift | `VoiceInputEngine` / `VoiceInputSession`、語音編輯偵測與套用、系統音訊、貼上。可獨立重用 |
| App | Swift | 視窗、設定、模型管理、歷史、匯出 |

App 不再有自己的 `AudioCapture`／`SystemAudioTap`／`CoreBridge`——這些重複已刪除，
App 走 Kit 的 `VoiceInputSession`。

Kit 是這個專案的產品目標之一：「把整套語音輸入方式打包成函式，放在另外一個資料夾，
之後可以再去調用。」`macos_app/Sources/VoiceInputKit/` 就是那個資料夾。CLI
（`Sources/voiceinput`）是它的命令列入口。

## 5. 核心設計決定

### 5.1 LLM 跑在獨立 worker 行程

`ovc-llm-worker`。每次 LLM 呼叫都是開一個行程、載入 GGUF、做完、退出。

理由：M1／8 GB。量測 Qwen3.5-2B 峰值 1,415–1,528 MB；常駐在 App 裡會把 ASR 擠出去。
每次呼叫後記憶體還給 OS。

代價：每個工作階段要重新載入模型（16–34 秒／三段摘要）。

**iOS 沒有這個選項**：行程不能 fork。所以 iOS 的 `run_task` 走 `run_in_process`，
LLM 與 ASR 同行程，靠 `gpu_layers` 與逾時保底（25 秒，低於 iOS 約 30 秒的背景時間）
控制風險。兩層降級——同一執行內重試（`llm_fallback_path`）與跨啟動記憶
（`LLMPolicy` 寫 App Group，下次 `Core.initialize` 時 `setenv`）——**macOS 也適用**，
只是 macOS 的降級訊息只寫 stderr，App 不顯示。細節與實測見
`docs/milestones.md` 的 M3。

### 5.2 ASR 用 Dolphin base int8

`asr/dolphin/model.int8.onnx`（99 MB）。同一段 5.6 秒音訊：

| 模型 | 解碼 | 峰值 RSS |
|---|---|---|
| Dolphin base int8 | 0.141 s (RTF 0.025) | 299 MB |
| SenseVoice int8 | 0.190 s | 452 MB |

40 種東南亞語言 + 22 種中國方言（含 `zh-MINNAN`）。CTC，非自回歸。
SenseVoice 保留為 fallback。

### 5.3 語音編輯：程式定位 + 模型改寫

使用者說「把第二點改成禮拜五」。程式把這句拆成：

```
指令     = "把第二點改成禮拜五"
目標位置 = 第 2 點          ← 程式解析
新值     = "禮拜五"         ← 程式解析
```

然後程式自己決定怎麼改：

| 指令類型 | 誰動手 | 例子 |
|---|---|---|
| 位置式取代 | 程式直接換那一行，不問模型 | 把第二點改成禮拜五 |
| 刪除 | 程式直接刪那一行 | 第三句刪掉 |
| 變換（沒有新值） | 模型重寫整行 | 把最後一句改短一點 |
| 整份草稿（定位不到） | 模型改寫整份 | 保留的 fallback |

「改短」不是「改成」——這是修過的真 bug。「改」原本被當成取值動詞，於是「改短一點」
被讀成新值「短一點」，整行被換成三個字。變換動詞（改短／改長／精簡／縮短…）不取值，
走模型重寫。

跨行重複的詞要拒絕：「把三點改成四點」而「三點」出現在兩行 → 該改哪行不可判定 →
拒絕（寧可不改）。

守門規則（防止模型胡來）：編號回覆才允許少行（少的是刪掉的）；純文字回覆行數必須
完全對上；單行改寫用「內容保留率」（原本的字至少留一半）。

量測：11/11 案例改到正確的行。

### 5.4 會議摘要 ≠ 聽寫整理

兩條不同的鏈。整理要的是「一行、不重複、別人看得懂」；會議要的是「摘要／決議／待辦」
三段，不能遺漏、不能編造負責人。

這不是偏好，是 bug 曾經發生的原因：會議逐字稿走聽寫提示詞，會被壓成一句話，
「誰答應什麼」就沒了。

Kit 的 `VoiceInputSession.Mode` 區分 `.dictation` / `.meeting`。

## 6. 2026-10-25 → 10-26 這一輪

起點：使用者說「你把全部的東西都做完」。剩下兩條線——語音編輯未實作、會議模式沒搬進 Kit。

| 提交 | 內容 |
|---|---|
| `9f01ba1` | 語音編輯：改成程式定位 + 模型改寫（原本整份草稿丟給模型，它會選錯行） |
| `0e78bc0` | App 接上核心已有的編輯能力（閘門太窄，核心會的指令 App 走不到） |
| `c3bd52b` | 會議逐字稿不再被聽寫提示詞改寫 |
| `9fe6dca` | ★ AX 取代路徑：改用回應鏈貼上 + 真實文字欄位測試 |
| `2d7cc3b` | CLI `--summarize` |
| `ffe6bcd` | 編輯探針改量產品路徑（6/11 → 11/11） |
| `747b3f8` | 浮動視窗修復：位置、處理階段、即時字、貼上 |

同時刪掉的三份 App 重複：`AudioCapture.swift`、`SystemAudioTap.swift`、`CoreBridge.swift`。

## 7. macOS 的兩個陷阱（都在 `9fe6dca` 裡踩到）

### 7.1 App 不會收到自己送出的合成按鍵事件

貼上用 CGEvent 丟到系統 HID tap，事件送給最前面的 App。所以：

- 貼到別的 App：正常（正常情況就是貼到別人輸入框）
- 貼到自己的視窗：完全沒反應，而 App 還回報「貼上成功」

修法：先用回應鏈（`NSApp.sendAction(#selector(NSText.paste(_:)))`），不行才退回 CGEvent。
回應鏈精準（不會貼錯 App），貼到別的 App 時碰不到這裡、CGEvent 接手。

### 7.2 貼上是事件，不是同步呼叫

Cmd+V 是丟到系統的事件，要經過 run loop。測試在主執行緒跑 → 不給 run loop 轉身 →
事件永遠不送達。

另外：視窗不是 key 就不會拿走焦點，欄位編輯器於是從來不是焦點元素。測試需要 App 是
`.regular`（附屬 App 不能成為最前面），且在啟動時就設定。

## 8. 這個專案最重要的發現

**量測工具自己壞掉時，它不會失敗，它會「測不到東西」。** 這個模式出現了至少四次，
每次都是真正的產品 bug 藏在哪裡。

| 量測原本在量 | 實際量的 | 揭出什麼 |
|---|---|---|
| 編輯探針量模型原始回覆 | 產品路徑 | 6/11 → 11/11 |
| AX 測試裡的診斷自己會貼一次 | 貼上根本沒發生 | 壞掉的取代看起來是好的 |
| 閘門只認位置 | 核心認得內容詞 | 8/4 的指令從 App 走不到 |
| 關鍵字檢索門檻 0.479 | 排序可靠、門檻不可靠 | 整條檢索線被 revert |

因此每個檢查都要做故障注入：故意弄壞 → 確認被抓到。`9fe6dca` 的兩個例子：

| 故意弄壞 | 結果 |
|---|---|
| 拒絕時謊報 `.pasted` | ❌ the refusal reported a paste |
| 選第一個出現的而不是游標前最後一個 | ❌ field is "昨天開會，然後今天開會", wanted "今天開會，然後昨天開會" |

第二個是最貴的失敗：使用者改一句話，結果變的是另一句，而且使用者看不到它發生。

另外兩條：

- **量到品質問題時，正確的決定是砍掉，不是降級。** 檢索（EmbeddingGemma）那條線效能
  修好了（11.8 s → 6.5 s），但量出來的召回品質不可用，於是整條線被 revert
  （`6fb4798`），265 MB 模型與快取都刪了。
- **「打包成可再調用」做完，不代表每個入口都接上了。** Kit 打包完成後才發現 Kit 有
  `engine.summarize` 而 CLI 叫不到。補了 `--summarize`。

## 9. 驗證：怎麼跑

```sh
scripts/build_macos.sh   # cargo build + test + swift build + 組 .app + 簽章
scripts/verify.sh        # 所有不需要人判斷的檢查
```

`scripts/verify.sh` 的檢查：

```
rust tests (84)          swift tests             cli self-test
cli edit                 cli summarize           voice edit probe (11 案)
offscreen ui (paper)     offscreen ui (night)    dictation end to end
audio import             meeting session         meeting session control
accessibility replacement
```

`scripts/ax_check.sh` 要對已安裝的 App 跑（輔助使用權限綁在已簽署的 bundle id 上），
且需要視窗伺服器——SSH 連進去跑不了。

離屏 UI 自檢用 `OVC_SELFTEST_UI=<dir> OVC_SELFTEST_UI_THEME=paper|night`，
**不要用螢幕截圖驗證**。

## 10. 模型與環境變數

| 變數 | 用途 |
|---|---|
| `OVC_LLM_MODEL` | LLM 檔名（只給檔名，接在 `<models>/llm` 下）。給了不存在的檔會 fallback 到 Qwen2.5-1.5B |
| `OVC_LLM_WORKER` | worker 路徑。App bundle 內自動找 `Contents/Frameworks` |
| `OVC_MODELS` | 模型樹根目錄 |
| `OVC_REFINE_STAGES` | 整理段數 `0`/`1`/`2` |

預設模型：`Qwen3.5-2B-Q4_K_M.gguf`（約 1.1 GB）。

建置必須序列：8 GB RAM，subagent 禁止執行 `cargo build` / `swift build`。

建置需要 sherpa-onnx：`core_engine/vendor/sherpa-onnx-v1.13.8-osx-arm64-shared`
（在 `core_engine/vendor/`，不是 repo 根的 `vendor/`）。

## 11. 還沒做的

| 項目 | 狀態 |
|---|---|
| 真人念一遍語音編輯 | 邏輯 11/11 過，但沒有人用麥克風試過 |
| 長會議（>5 分鐘）切段去重 | 有單元測試，沒在真實錄音上跑過 |
| 台語（Minnan） | 模型支援 `zh-MINNAN`，沒有人用耳朵聽過 |
| 簽章／公證 | 只做 ad-hoc 簽章 |
| 資料刪除 UI | 未實作（錄音狀態指示器有） |
| iOS | 程式與模擬器實測到 M4（M0–M3 完成、M4/M5 部分），已完成 plan／review／debug 四輪複查；進度與完成定義見 `docs/milestones.md`（附錄 A–D 是四輪修掉的東西）；M6 全項待真機 |
| Android | 只有設計筆記 |
