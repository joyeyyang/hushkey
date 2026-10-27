# iOS 版里程碑（M0–M6）

這份文件的用途只有一個：**每個階段「做完」的定義寫死在這裡，做完就打勾。**
沒有寫在這裡的工作不算完成，寫在這裡但沒打勾的不算做完。

狀態代號：`[x]` 完成並有佐證 · `[~]` 程式完成但佐證不足 · `[ ]` 未開始

## 現況總覽（2026-10-27）

| 里程碑 | 狀態 | 還缺什麼 |
|---|---|---|
| M0 啟動不是白畫面 | `[x]` | — |
| M1 核心在 iOS 跑得起來 | `[x]` | — |
| M2 錄音→辨識→落字 | `[x]` | — |
| M3 AI 整理＋2B／降級 | `[x]` | 2B 的**速度**數字只有真機有意義 |
| M4 PiP 零跳轉 | `[~]` | 模擬器不支援 PiP，PiP 視窗本身只能在真機驗 |
| M5 真機安裝與模型 | `[~]` | 需要插線＋付費帳號開 App Group |
| M6 真機實測 | `[ ]` | 全部，只有真機能量 |


---

## 為什麼是這些里程碑

iOS 版的難處不在功能，在**三個平台限制**：

1. **鍵盤擴充不能開麥克風。** CoreMedia 在權限彈窗前就擋掉（FB16791704），
   而且鍵盤記憶體上限約 77 MB。所以錄音與辨識只能放在 App，鍵盤只負責落字。
2. **App 切出去只有約 30 秒背景時間。** 辨識 + LLM 整理必須在這段時間內完成，
   或至少要有「時間到就交出來」的保底。
3. **手機沒有 shell。** 模型要怎麼進到裝置，本身就是一個功能，不是部署細節。

這三點決定了 M0–M6 的切法：先讓東西跑得起來（M0–M2），再讓它好用（M3–M4），
最後才可能在真機上說「能用」（M5–M6）。

---

## M0 — App 能啟動，不是白畫面

**為什麼需要**：iOS 的 SwiftUI `@main` 若沒有 `UIApplicationSceneManifest`，
App 會啟動、不崩、不連 scene、只顯示白畫面，log 一片空白。

**完成定義**
- [x] `Sources/App/Info.plist` 明確宣告 `UIApplicationSceneManifest`
- [x] `Diagnostics.swift` 在 boot 時用 `os.Logger` 印出可判讀的啟動報告
      （bundle / 系統 / scene / App Group / 模型狀態）
- [x] 模擬器截圖證明看得到介面，不是白畫面

**佐證**：commit `6630065`；`log show` 可見 `[boot] scene=manifest present ok=true`。

---

## M1 — 核心在 iOS 上跑得起來

**為什麼需要**：Rust 核心原本假設「LLM 跑在獨立 worker 行程」—— macOS 可以 fork，
iOS 不行。這一步是讓同一份 C ABI 在 iOS 上也能用。

**完成定義**
- [x] `core_engine` 編得出 `aarch64-apple-ios-sim` 與 `aarch64-apple-ios` 兩個 slice
- [x] C ABI（`Core_Initialize` / `Agent_Load` / `ASR_*` / `LLM_*`）在 iOS 可呼叫
- [x] ASR 模型（Dolphin base int8）能在 iOS 上載入並辨識
- [x] 兩件引擎事實被記錄下來：`Core_Initialize` 只指定模型樹，必須 `Agent_Load("asr")`；
      core 預設挑 SenseVoice，iOS 用 `setenv("OVC_ASR_MODEL", "dolphin", 1)` 改選

**佐證**：sim 版 `liboffline_voice_core.a` 建置成功；`[boot] models=found`；
注入音檔後 `dictation done: 27 chars`。

---

## M2 — 錄音 → 辨識 → 文字落進別的 App

**為什麼需要**：這是產品的核心迴路。鍵盤不能錄音，所以流程跨兩個行程，
中間只能靠 App Group 傳字。

**完成定義**
- [x] 鍵盤擴充（純 UIKit，不掛 SwiftUI，省記憶體）有麥克風鍵、即時字幕、複製、插入
- [x] `RequestsOpenAccess=true`，App Group `group.com.example.offlinevoiceassistant`
- [x] `SharedStore` 的 `Session`（phase / partial / text / detail / consumed）+ Darwin 通知
- [x] 錄音邊錄邊落地成 WAV（16 kHz mono float32），App 被砍也不掉字
- [x] 靜音自動停止（1.2 秒、前 0.5 秒學底噪、上限 60 秒、至少 0.35 秒語音）
- [x] 注入音檔後，文字真的出現在另一個 App 的游標位置

**佐證**：commit `1eb241e`；注入 `say -v Meijia` 合成音 → 鍵盤落在 TextEditor
游標處 27 字。真麥克風路徑（`-OVC_RECORD`）也驗過靜音自動停止 + publish。

---

## M3 — AI 整理（LLM 在 App 行程內）

**為什麼需要**：ASR 的原始輸出有口頭禪、沒有標點、簡繁混雜。整理是產品價值的一半。
iOS 不能 fork，所以 LLM 必須在 App 行程內跑，這帶來兩個新風險：
記憶體與時間。

**完成定義**
- [x] `state.rs` 的 `run_task` 依平台分流：iOS 走 `run_in_process`，macOS 走 worker
- [x] `Core.refine` 接上 `LLM_RefineTextWithKeywords`
- [x] App 有「AI 整理」開關（預設開），關掉就送原文
- [x] **預設模型是 Qwen3.5-2B**（`Qwen3.5-2B-Q4_K_M.gguf`），不是小模型
- [x] 2B 跑不動時**自動降級**到備援模型，且**兩層都要留紀錄**
      （同一執行內重試 + 跨啟動記憶）
- [x] 整理逾時有保底：時間到就發布未整理原文，不留「整理中…」卡死
- [x] 音檔**發布成功後**才刪，App 中途被系統砍掉時下次啟動補辨識
- [x] 補辨識時**跳過整理**，不讓同一個原因再殺一次

**佐證要求**：`cargo test` 覆蓋降級選擇邏輯；模擬器 log 出現
`refine overran its deadline; publishing as heard` 後仍有 `dictation done`。

**已取得的佐證（2026-10-27，模擬器 iPhone 17 / iOS 26.0）**

```
llm=preferred · Qwen3.5-2B-Q4_K_M.gguf ok=true          ← 開機就宣告預設是 2B
refine overran its deadline; publishing as heard        ← 25 秒保底
llm model downgrade recorded: Qwen3.5-2B-Q4_K_M.gguf → qwen2.5-0.5b-instruct-q4_k_m.gguf
  — 整理超過 25 秒，未在背景時間內完成 (applies from the next launch)
dictation done: 27 chars                                ← 沒整理也把字交出來
```

下一次啟動（同一個 App，沒有改任何設定）：

```
llm=Qwen3.5-2B-Q4_K_M.gguf → qwen2.5-0.5b-instruct-q4_k_m.gguf · 整理超過 25 秒…
llm model: using qwen2.5-0.5b-instruct-q4_k_m.gguf instead of Qwen3.5-2B-Q4_K_M.gguf
dictation done: 23 chars                                ← 9.5 秒完成，整理成功
```

三件事同時被證明：預設是 2B、跑不動會**自動**降級、降級**有紀錄**且**跨啟動有效**。
降級在 UI 上也看得到（模型頁顯示「AI 整理已降級」與原因，並有「重新嘗試大模型」）。


---

## M4 — PiP 零跳轉（Mode 2，可選）

**為什麼需要**：Mode 1 按麥克風會跳 App。Typeless 的「實心麥克風＝不用切換」
靠的是 PiP：App 用 `AVPictureInPictureVideoCallViewController` 常駐小窗，
麥克風只在說話時開，鍵盤用 Darwin 通知觸發，全程不離開原本的 App。

**完成定義**
- [x] `PiPController`（`AVPictureInPictureVideoCallViewController` + `AVSampleBufferDisplayLayer`）
- [x] `UIBackgroundModes: audio`，PiP 期間音訊 session 保持活著
- [x] 鍵盤用 Darwin 通知觸發錄音（不再開 `ovc://record`）
- [x] 鍵盤即時字幕在 PiP 模式下也更新
- [x] App 內有開關：Mode 1（預設）/ Mode 2
- [x] 模擬器能驗多少驗多少；PiP 小窗行為標記「待真機」

**注意**：PiP 在模擬器上不保證可用。這一步的完成定義包含
「明確標記哪一部分只能在真機驗」，不是假裝驗過了。

**模擬器實測結果（2026-10-27）**：`AVPictureInPictureController.isPictureInPictureSupported()`
在 iPhone 17 模擬器（iOS 26.0）回 **false**，log：

```
pip probe: requested at launch
pip: start requested
pip: unsupported on this device; falling back to Mode 1
```

所以 M4 在模擬器上的正確結果就是「不支援並退回 Mode 1」，UI 也會顯示
「這台裝置不支援小窗（PiP），已改回跳回 App。」。**PiP 視窗本身、背景存活、
零跳轉落字，只能在真機驗（M6）。**

**這一步的設計要點**：Mode 2 不信任「使用者選了」這個事實，而是信任
`SharedStore.pipLive`（PiP delegate 寫入）。PiP 沒真的起來時，鍵盤按麥克風仍走
`ovc://record`，不會變成一個沒有反應的按鈕。


---

## M5 — 真機裝得起來、模型進得去

**為什麼需要**：手機沒有 shell。模型怎麼進裝置、鍵盤怎麼被啟用，
是真機能不能用的前提，不是部署細節。

**完成定義**
- [x] App 啟動時**自動建立** `models/asr/dolphin/` 與 `models/llm/`
- [x] 模型頁顯示兩個模型各自狀態（辨識必要／AI 整理選用）
- [x] 支援「檔案或資料夾」匯入（依副檔名分類：`.gguf` → `llm/`，`.onnx`/`.txt` → `asr/dolphin/`）
- [x] `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`，
      可用 Finder／「檔案」App 直接拖進去
- [x] 模型同時支援 App Group 與 App Documents 兩個位置（只有 App 讀模型）
- [ ] 真機上完成一次「安裝 App → 放模型 → 鍵盤啟用 → 落字」全流程
- [ ] App Group 能力在開發者後台註冊（免費帳號不支援，需要付費帳號）

**最後兩項需要使用者配合**（插線、開發者帳號），其餘是程式工作。

---

## M6 — 真機實測：速度、記憶體、PiP

**為什麼需要**：模擬器的 Metal 不可靠、記憶體也不代表手機。所有「快不快、
撐不撐得住、PiP 會不會被系統收掉」只有真機能回答。

**完成定義**
- [ ] 真機上 2B 模型的：模型載入秒數、整理耗時、峰值記憶體
- [ ] 若 2B 超出背景時間或記憶體不足 → **記錄實際數字**後才降級，不是憑感覺
- [ ] 降級後 0.5B 的同三項數字
- [ ] Mode 1 全流程：按麥克風 → 跳 App → 說完 → 返回 → 文字出現
- [ ] Mode 2 全流程：PiP 小窗、零跳轉、鍵盤即時字幕
- [ ] 鍵盤在第三方 App（Messages / Safari / Notes）都能落字
- [ ] 上述每一項都有截圖或 log，不是「應該可以」

**這一步沒有程式碼可寫，只有量測與修正。** 量不到的項目要明確寫「量不到」，
不能寫「應該沒問題」——`docs/PROJECT.md` 第 8 節記的正是這件事：
量測工具自己壞掉時它不會失敗，它會測不到東西。

---

## 依賴關係

```
M0 ──> M1 ──> M2 ──> M3 ──> M4
                      │
                      └──> M5 ──> M6
```

M5 的程式部分（模型安裝）可以與 M3/M4 平行做，但**真機驗證**必須等 M5 的
帳號與插線條件齊備。M6 依賴 M2、M3、M4、M5 全部完成。

---

## 附錄：最基礎五步的實測紀錄（2026-10-27）

要求是「先做最基礎版，而且真的能用」。以下五步都在模擬器 iPhone 17
（`8E73CE6B-A4D1-4268-AE3D-B75C95A5BCB8`，iOS 26.0）上跑過。

| 步 | 動作 | 佐證 |
|---|---|---|
| 1 | 按麥克風 → 錄到音 | `-OVC_RECORD` 走真麥克風路徑（先前已驗）；本次用注入音檔走同一條 `AudioSpool` → `MicCapture` 之外的路徑 |
| 2 | ASR 出字 | log：`recogniser ready` → `dictation done: 23 chars` |
| 3 | 文字出現在畫面 | 截圖 `m3-trad-28s.png`：畫面顯示「今天下午三点要跟王经理开会，讨论下个季度的预算」 |
| 4 | 可複製、可清除 | 截圖：`複製` / `清除` 兩鍵在文字下方，狀態為「完成」 |
| 5 | 鍵盤把字插進別的 App | 截圖 `m2-insert-30s.png`：KB probe 的 TextEditor 出現 46 字（同一句被插入兩次，probe 的既有內容＋新插入） |

**已知缺陷（寫下來，不假裝沒有）**：上面第 3 步的字是**簡體**。ASR（Dolphin）
在台灣口音上輸出簡體，而 0.5B 的整理沒有把字轉成繁體——即使提示詞要求、範例也示範了。
這是「降級模型的品質代價」的具體樣貌：2B 尚未在真機上驗證是否能正確轉換。
處理順序是先在真機確認 2B 的輸出，再決定是否需要在程式裡做簡繁轉換
（不靠模型，才不會隨模型大小而變）。

## 怎麼重跑這些佐證

```bash
# 核心測試（降級、整理、摘要在內）
cargo test --manifest-path core_engine/Cargo.toml

# 模擬器 slice
SHERPA_ONNX_DIR="$PWD/core_engine/vendor/ios/sim" \
  cargo build --manifest-path core_engine/Cargo.toml --target aarch64-apple-ios-sim --release
cp -f core_engine/target/aarch64-apple-ios-sim/release/liboffline_voice_core.a ios_app/vendor/sim/

# 真機 slice
SHERPA_ONNX_DIR="$PWD/core_engine/vendor/ios/device" \
  cargo build --manifest-path core_engine/Cargo.toml --target aarch64-apple-ios --release
cp -f core_engine/target/aarch64-apple-ios/release/liboffline_voice_core.a ios_app/vendor/device/

# App
cd ios_app && xcodegen generate
xcodebuild -project OfflineVoiceAssistant.xcodeproj -scheme OfflineVoiceAssistant \
  -sdk iphonesimulator -configuration Debug -derivedDataPath build \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY="-" build

# 行為
xcrun simctl launch <sim> com.example.offlinevoiceassistant.ios -OVC_KB_PROBE -OVC_AUDIO_FILE <wav>
xcrun simctl spawn <sim> log show --last 2m \
  --predicate 'subsystem == "com.example.offlinevoiceassistant.ios"' --style compact
```
