# iOS 版里程碑（M0–M6）

這份文件的用途只有一個：**每個階段「做完」的定義寫死在這裡，做完就打勾。**
沒有寫在這裡的工作不算完成，寫在這裡但沒打勾的不算做完。

狀態代號：`[x]` 完成並有佐證 · `[~]` 程式完成但佐證不足 · `[ ]` 未開始

## 現況總覽（2026-10-27）

| 里程碑 | 狀態 | 還缺什麼 |
|---|---|---|
| M0 啟動不是白畫面 | `[x]` | — |
| M1 核心在 iOS 跑得起來 | `[x]` | — |
| M2 錄音→辨識→落字 | `[~]` | 落字只驗到本 App 的 probe 畫面；第三方 App 在 M6 |
| M3 AI 整理＋2B／降級 | `[x]` | 2B 的**速度**數字只有真機有意義 |
| M4 PiP 零跳轉 | `[~]` | 模擬器不支援 PiP，PiP 視窗本身只能在真機驗 |
| M5 真機安裝與模型 | `[~]` | 需要插線＋付費帳號開 App Group |
| M6 真機實測 | `[ ]` | 全部，只有真機能量 |

2026-10-27 已跑完 plan／review／debug 三輪複查：review 的 12 項見附錄 A，
debug 的 7 項見附錄 B，第三輪回頭審「前兩輪修得對不對」找到的 9 項見附錄 C。
文件裡的「佐證」只寫真的跑過的，量不到的一律標成「待真機」或「程式碼層」，不寫「應該可以」。


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
- [x] 鍵盤擴充（純 UIKit，不掛 SwiftUI，省記憶體）最上方**只有三樣**：
      麥克風、即時字幕、複製——與 macOS 版 HUD 同功能，沒有第四顆「插入」
      （收到逐字稿時本來就會自動插入，多一顆只是同一段字再插一次）
- [x] 語音列下方是**完整可打字的 QWERTY**（q/a/z 三排＋⇧＋⌫＋空白＋換行＋🌐）。
      這是必要的，不是附加品：本擴充會**取代**系統鍵盤，沒有字母鍵等於把打字拿掉
- [x] `RequestsOpenAccess=true`，App Group `group.com.example.offlinevoiceassistant`
- [x] `SharedStore` 的 `Session`（phase / partial / text / detail / consumed）+ Darwin 通知
- [x] 錄音邊錄邊落地成 WAV（16 kHz mono float32），App 被砍也不掉字
- [x] 靜音自動停止（1.2 秒、前 0.5 秒學底噪、上限 60 秒、至少 0.35 秒語音）
- [x] 注入音檔後，文字真的出現在**游標位置**（`textDocumentProxy.insertText`）

**佐證**：commit `1eb241e`；注入 `say -v Meijia` 合成音 → 鍵盤落在 TextEditor
游標處 27 字。真麥克風路徑（`-OVC_RECORD`）在**上一輪**驗過靜音自動停止 + publish，
本輪沒有重跑（見下方五步表第 1 列的邊界）。

**序號是單調的（第二輪複查修掉，2026-10-27 21:49–21:59）**：`publish` 的序號原本由
已發布的那一筆 +1 推算，而 `clear()` 會刪掉那一筆，於是清除後序號從 1 重數；
鍵盤已經插過第 3 句、`consumedSeq = 3`，接下來的新句子在序號爬回 3 之前全部被當成
「插過了」，**連續數句不落字、畫面上沒有任何解釋**。序號改成獨立計數器 `s.seq`，
`clear()` 不碰它（也不碰 `consumedSeq`），而下一號取 `max(s.seq, published.seq) + 1`
——後者涵蓋升級：舊安裝沒有 `s.seq`，`consumedSeq` 卻可能已經是 6。實測：

```
（清除後）s.seq 停在 5（清除不動它）| consumedSeq = 3 | published.seq = 無
（新的一句）s.seq = 6 | published.seq = 6          ← 沒有回退
（鍵盤插字）consumedSeq = 6                        ← 只插一次，截圖 d3-insert-after-clear.png
（升級模擬：刪掉 s.seq、published.seq = 6、consumedSeq = 6）
（新的一句）s.seq = 7 | published.seq = 7
（鍵盤插字）consumedSeq = 7                        ← 截圖 d4-upgrade-insert.png
```

**整句重複的規則也直接驗了**：`-OVC_MERGE_PROBE` 把「核心的 `join_speech` 會補空白、
這一側直接串接」這個組合餵給 `merge()`：

```
merge: 開會用 Notion 記錄        ← 舊版會變成「開會用Notion記錄開會用 Notion 記錄」
merge: 今天下午三點要開會        ← 中文對中文，兩邊字串相同
merge: 只有核心的話              ← 這一側是空的
merge: 只有這一邊                ← 核心回空字串
```

這條規則只能用探針驗，不能用音檔驗：模擬器上的 Dolphin 會把英文與數字正規化成
中文（連 `-OVC_ASR_LANGUAGE=en` 都沒輸出），所以「中文＋英文專有名詞」這個觸發條件
在音檔路徑上重現不出來。

**佐證的邊界（要說清楚）**：這裡的 TextEditor 是**本 App 自己的** `-OVC_KB_PROBE`
測試畫面，也就是「這個鍵盤擴充在同一台裝置上把字插進一個文字欄位」。
它證明的是 `textDocumentProxy.insertText` 這條路會通、字是真的進了欄位，
**不是**「已驗過第三方 App」。Messages／Safari／Notes 的落字需要真機，
列在 M6 的完成定義裡，在 M6 打勾前不能算完成。

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
      （① 同一執行內重試：只在引擎**回報錯誤**時發生；**逾時不重試**，直接發布原文並記錄
      ② 跨啟動記憶：下次啟動直接指定小模型）
- [x] 整理逾時有保底：時間到就發布未整理原文，不留「整理中…」卡死
- [x] 音檔**發布成功後**才刪，App 中途被系統砍掉時下次啟動補辨識
- [x] 補辨識讀得回「標頭沒寫完」的 WAV：程式被砍時 `AVAudioFile` 來不及把長度寫進標頭，
      檔案裡的聲音卻全在。讀不到長度就改讀 `data` chunk，實測有效（見下）
- [x] 補辨識時**跳過整理**，不讓同一個原因再殺一次

**佐證要求**：`cargo test` 覆蓋降級選擇邏輯；模擬器 log 出現
`refine overran its deadline; publishing as heard` 後仍有 `dictation done`。

**已取得的佐證（2026-10-27 21:21–21:23，模擬器 iPhone 17 / iOS 26.0，本輪重新跑過）**

第一次啟動（先把降級記錄清掉，讓它真的回到 2B）：

```
llm=wanted Qwen3.5-2B-Q4_K_M.gguf · installed Qwen3.5-2B-Q4_K_M.gguf ok=true
recogniser ready
dictation injected: probe.wav
refine overran its deadline; publishing as heard                     ← 25 秒保底
llm model downgrade recorded: Qwen3.5-2B-Q4_K_M.gguf → qwen2.5-0.5b-instruct-q4_k_m.gguf
  — 整理超過 25 秒，未在背景時間內完成 (applies from the next launch)
the abandoned cleanup pass still occupies the work queue             ← 逾時不取消，誠實記錄
dictation done: 27 chars                                            ← 沒整理也把字交出來
```

下一次啟動（同一個 App，沒有改任何設定）：

```
llm=wanted Qwen3.5-2B-Q4_K_M.gguf · using qwen2.5-0.5b-instruct-q4_k_m.gguf · 整理超過 25 秒，未在背景時間內完成 ok=true
llm model: using qwen2.5-0.5b-instruct-q4_k_m.gguf instead of Qwen3.5-2B-Q4_K_M.gguf — 整理超過 25 秒…
recogniser ready
dictation injected: probe.wav
dictation done: 23 chars                        ← 22 秒（含解碼），這次沒有逾時
```

三件事同時被證明：預設是 2B、跑不動會**自動**降級、降級**有紀錄**且**跨啟動有效**。
降級在 UI 上也看得見（模型頁顯示「AI 整理已降級」與原因，並有「重新嘗試大模型」）。

**但第一行只能讀到「請求的是 2B」**：`llm=wanted … · installed …` 是
`LLMPolicy.apply()` 在把選擇講出來，它證明偏好與檔案都在，**不證明 2B 真的載入並作答**
（那次整理逾時，`Core.lastModelName()` 的回報路徑根本沒走到）。真正的「誰作答」證據是
`LLM_LastModelName`，而它只有整理**成功**時才會被讀，所以模擬器這一輪拿不到。
「2B 在這台機器上跑起來了」這件事要等真機（M6）。

**量到的另一件事**：0.5B 在**這台**機器上不穩定——同一個測試音跑兩次，
一次 22 秒完成整理、一次超過 25 秒。所以「降級之後就一定過」是錯的；
如果再逾時，log 會改說 `qwen2.5-0.5b… also overran; nothing smaller is installed`，
不會再記一筆看起來像進展的降級。第二輪複查補了一個相關漏洞：降級的起點原本固定是
「偏好的那個模型」，所以裝了 2B／1.5B／0.5B 三顆時，第二次失敗會再選一次 1.5B
（就是剛剛超時的那顆），log 還會說「沒有更小的模型」而 0.5B 明明就在旁邊。
現在起點是**實際生效的**模型（`activeName ?? preferredName`），可以一路 2B → 1.5B → 0.5B。

**這份佐證的但書（不能拿它推論真機）**：上面的 2B 逾時是模擬器上的結果，
而模擬器 slice 的 LLM 是**強制 CPU、`gpu_layers=0`**（`target_abi="sim"`，
因為 Metal 在模擬器會卡在 `__ggml_metal_rsets_init_block_invoke`）。
真機是 `gpu_layers=99` 全 offload。也就是說：

- 這份 log 證明的是**降級機制會自己動、而且留下紀錄**——這是 M3 要的東西。
- 它**不能**用來宣稱「2B 在 iPhone 上跑不完 25 秒」。真機的 2B 是 GPU 加速，
  速度結論只有 M6 能量。模擬器的記錄是模擬器的事實，不是手機的結論。

**補辨識讀得回壞掉的標頭（同一輪實測）**：把一段正常 WAV 的 `data` chunk 長度欄位
改成 0（模擬「程式被砍、標頭沒寫完」），放進 `<group>/spool/`，再把修改時間設成 2 分鐘前：

```
recovering spool deadbeef-orphan.wav
dictation injected: deadbeef-orphan.wav
spool had no usable header; read the data chunk directly
dictation done: 27 chars
```

補回來的字是**原文**（`skipRefine`，如設計），畫面上也真的插進去了（27 字，截圖
`r2-insert.png`）。順帶看到原始輸出長什麼樣：「今天下午下午三點…」——ASR 的重複詞
只有整理階段會修掉，而這條路刻意跳過整理。

**補辨識的四條邊界（第二、三輪複查後改的，都是實測）**：

1. **等 1.5 秒才開始。** 從鍵盤按麥克風的冷啟動是「先開 App、再走 `onOpenURL` 開始錄音」，
   補辨識若搶在前面，會占住麥克風二十幾秒，使用者對著一個「其實還沒開始」的錄音講話。
   現在啟動後 1.5 秒才補；這個延遲對**每一次啟動**都成立，只是只有麥克風路徑會在那個
   窗口內搶到 `start()`。
2. **補辨識期間不再謊報「錄音中」。** 這條路徑原本把共享 phase 設成 `.recording`，
   於是鍵盤顯示「錄音中…」，而麥克風根本沒開——使用者對著一場不會發生的錄音講話。
   現在它對外是 `.transcribing`＋「補回上次的錄音…」。實測（啟動後 2 秒讀共享狀態）：

```
s.phase = transcribing
s.detail = 辨識中…
dictation injected: bbbb0002-new.claimed
dictation done: 27 chars
```

3. **清除會收走已發布的句子與 spool，也真的能取消進行中的補辨識**（`-OVC_CLEAR`
   在 2 秒後觸發）。用一段 10.5 秒的音檔當 orphan，讓解碼跑得夠久，清除這次落在
   解碼途中：

```
recovering spool eeee0003-long.wav
dictation injected: eeee0003-long.claimed
clear requested at launch            ← 落在解碼途中，不是發布之後
（結果）s.phase = idle · s.published 不存在 · s.seq 沒有變 · spool 目錄空
```

   沒有任何 `dictation done`——那句話不會晚一步冒出來。短音檔的情況（清除晚於發布）
   也驗過：句子被收走、spool 清空、重開 App 時 `recovering spool` 出現 **0 次**。

4. **舊的 orphan 留給下一次啟動，但要先「認領」。** 補辨識自己也會寫一份 spool；
   被砍第二次的話，半途那份變成「最新」。原本這裡會把舊的清掉，那等於把完整的原檔
   連同半成品一起刪掉——「不會掉字」在這裡反而變成掉字。現在保留舊的，選中的那一份
   先改名成 `*.claimed`（離開 `orphans()` 的候選集）再解碼。**這一條是雙面的**：
   不認領的話，下一次啟動會撿到原檔並把同一句再插一次（實測重現過）；認領之後，
   被砍第二次的那句話就不會交付，只留下一個 `.claimed` 檔與一行
   `recovery abandoned N claimed spool(s)`。`.claimed` 一起算進 `prune` 的上限。
   另外 `orphans()` 只挑 mtime 在 3 秒～**600 秒**之間的檔案，超過十分鐘的 spool
   不會被補，只會等 `prune` 收掉。


---

## M4 — PiP 零跳轉（Mode 2，可選）

**為什麼需要**：Mode 1 按麥克風會跳 App。Typeless 的「實心麥克風＝不用切換」
靠的是 PiP：App 用 `AVPictureInPictureVideoCallViewController` 常駐小窗，
麥克風只在說話時開，鍵盤用 Darwin 通知觸發，全程不離開原本的 App。

**完成定義**
- [~] `PiPController`（`AVPictureInPictureVideoCallViewController` + `AVSampleBufferDisplayLayer`）
      ——程式完成；模擬器連 `isPictureInPictureSupported()` 都是 false，**執行期沒被走過**
- [x] `UIBackgroundModes: audio`（`Info.plist` 內含 `audio`，可直接查證）
- [~] 鍵盤用 Darwin 通知觸發錄音（Mode 2）；`ovc://record` 保留為**退路**——
      通知沒有回執，所以送出後 1.5 秒內沒看到 `.recording` 就改回開 App，
      不讓「選了 Mode 2 但小窗沒活著」變成按了沒反應的鍵（程式完成，未在真機上走過）
- [~] 鍵盤即時字幕在 PiP 模式下也更新（同一條輪詢路徑，PiP 模式本身未驗）
- [x] App 內有開關：Mode 1（預設）/ Mode 2（截圖可見，平面、無膠囊）
- [~] 模擬器能驗多少驗多少；PiP 小窗行為標記「待真機」
      （模擬器已驗到的只有「不支援 → 誠實退回 Mode 1」，見下）

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
`SharedStore.pipAlive`（PiP 心跳）。PiP 沒真的起來時，鍵盤按麥克風仍走
`ovc://record`，不會變成一個沒有反應的按鈕。

**心跳而不是旗標**：`pipLive` 只在 PiP delegate 裡寫 `true`，但 delegate 不會在
「行程被砍」時執行，於是它會永遠停在 `true`，鍵盤就一再把麥克風點擊吞掉。現在 App 每秒
蓋一次章（`pipLive` + `pipLiveAt`），鍵盤只在章還新鮮時才相信它。新鮮度訂在 **20 秒**：
主執行緒在匯入模型時可以卡好幾秒，而誤判的代價是「使用者被強迫跳 App 一次」，比多等幾秒
更糟。**這條新鮮度本身沒有實測**——模擬器連 PiP 都起不來，心跳根本不會跑，只有真機能驗。
在模擬器上驗到的是「殘留的旗標在啟動時會歸零」（先手動把 `pipLive` 寫成 1、`pipLiveAt` 寫成
遠古時間）：

```
（啟動前）pipLive = 0 → 手動寫成 1
pip probe: requested at launch
pip: start requested
pip: unsupported on this device; falling back to Mode 1
（啟動後）pipLive = 0
```

也就是「上一次執行的旗標」不會被當成「這一次的事實」。


---

## M5 — 真機裝得起來、模型進得去

**為什麼需要**：手機沒有 shell。模型怎麼進裝置、鍵盤怎麼被啟用，
是真機能不能用的前提，不是部署細節。

**完成定義**
- [x] App 啟動時**自動建立** `models/asr/dolphin/` 與 `models/llm/`
- [x] 模型頁顯示兩個模型各自狀態（辨識必要／AI 整理選用）
- [x] 「模型已安裝」的判斷**與核心真正會載入的檔案一致**：SenseVoice 是
      `asr/model.int8.onnx`（或 `model.onnx`）＋`asr/tokens.txt`，Dolphin 是
      `asr/dolphin/model.int8.onnx`＋同層 `tokens.txt`。原本是寬鬆的「有 `.onnx`
      也有 `tokens.txt` 就算」，結果一個核心拒絕的資料夾會被顯示成「已安裝」，
      錯誤延後到第一次聽寫才爆——而那正是 M5 這個畫面要避免的事
- [x] 支援「檔案或資料夾」匯入（`.gguf` → `llm/`；`.onnx` → `asr/`，
      但來源路徑含 `dolphin` 就進 `asr/dolphin/`；`tokens.txt` 跟隨已安裝的那一個）
- [x] `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`，
      可用 Finder／「檔案」App 直接拖進去
- [x] 模型同時支援 App Group 與 App Documents 兩個位置（只有 App 讀模型）
- [ ] 真機上完成一次「安裝 App → 放模型 → 鍵盤啟用 → 落字」全流程
- [ ] App Group 能力在開發者後台註冊（免費帳號不支援，需要付費帳號）

**匯入的分類規則**（唯一沒被真機驗過的部分是「拖進來的路徑長什麼樣」）：
`.gguf` 一律進 `llm/`；`.onnx` 看**來源路徑**有沒有 `dolphin` 決定進 `asr/` 還是
`asr/dolphin/`；`tokens.txt` 不自己選資料夾，跟著「已經有模型的那一個」——
Dolphin 與 SenseVoice 的 token 表不同，跟著錯的那個會讓辨識在載入時才失敗。

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

## 附錄 A：review 之後修掉的東西（2026-10-27）

程式碼自己會跑，不代表它做對。這一輪請 review 子代理逐檔審查，找出的是
**真的會壞的路徑**，不是風格問題。修完都在模擬器上重跑過。

| # | 缺陷（原本會怎樣） | 修法 | 驗證 |
|---|---|---|---|
| 1 | `fail()` 只關麥克風，沒關 ASR session。Rust 拒絕第二次 `Core.start()`，**同一輪啟動之後每次按麥克風都失敗**，只能重啟 App | `fail()` 內補 `try? Core.stop()`（在 `work` 佇列上） | 建置後注入音檔正常 |
| 2 | 按「清除」後，先前已在跑的 decode 照樣 publish——**清掉的字又自己回來** | 每次聽寫一個 `generation`；decode／整理／逾時／背景到期／即時字幕全部比對，不符就丟 | 程式碼層；清除路徑不再有競態 |
| 3 | `attach()` 先建 spool 檔再開麥克風，開失敗時檔案留在 `spool/`；解不開的 orphan 永遠不刪 → **每次啟動都重跑一次註定失敗的補辨識** | 開麥克風失敗就 `discard()`；`fail()` 刪掉 `orphanSource` | 見 M3 的壞標頭實測 |
| 4 | 鍵盤在**不可見**時也 `insertPending()`，而且 `markConsumed()` 無條件執行 → 字沒進欄位卻被標記「已用完」，**永久遺失** | `guard view.window != nil`；插入後帶序號 `markConsumed(seq)` | 截圖 `r2-insert.png`；重開為 0 字 |
| 5 | `SharedStore` 每個操作都「讀整個 session → 改一格 → 寫回」，兩個行程互撞 → 最壞情況是 phase 被寫回 `.done`，**整次聽寫的即時字幕凍結** | 拆成一欄一 key；`publish` 的 text＋序號合成**單一原子寫入** | 錄音中即時字幕正常；`s.published` 與 `s.consumedSeq` 分開可查 |
| 6 | `publish` 沒有身分，同一段結果被兩條路徑各發布一次 → **同一句插兩次**（就是舊紀錄裡的 46 字） | 序號 + 鍵盤記錄插過的序號 + `publishedGeneration` | 27 字一次，重開 0 字 |
| 7 | `pipLive` 只在 delegate 裡清，App 被砍就永遠留 `true` → Mode 2 的麥克風變成**按了沒反應** | 改成心跳（每秒蓋章、新鮮度 20 秒）＋啟動時歸零＋送出請求 1.5 秒無回應就退回開 App | 把 `pipLive` 手動寫成 1 再啟動 → `pipLive = 0`，log 見 `pip: unsupported → falling back to Mode 1` |
| 8 | PiP 啟動失敗後 `pip` 沒清，之後 `start()` 永遠早退 → 選了 Mode 2 卻什麼都不會發生 | 失敗／關窗都釋放 controller，再選就重試 | 程式碼層 |
| 9 | ⇧ 走訪 `view.subviews` 找按鍵，層級錯一層 → **按 shift 畫面完全沒反應**（輸入卻變大寫） | 建鍵時存進 `letterKeys`，直接改那批按鈕 | 程式碼層（觸控未自動化） |
| 10 | 程式被砍時 WAV 標頭沒寫完，補辨識讀到 0 格 → 「不會掉字」只是口號 | 讀不到長度就改讀 `data` chunk | log：`spool had no usable header; read the data chunk directly` → `dictation done: 27 chars` |
| 11 | 0.5B 也逾時時仍記一筆「已降級」→ log 看起來像有進展 | 已在最小模型就明說「沒有更小的」 | 程式碼層（第二輪把措辭與起點都改了，見附錄 B #7） |
| 12 | `onAppear` 可能跑兩次 → 重複載入 100 MB 辨識模型 | `prewarmed` 旗標 | log 只剩一則 `recogniser ready` |

**刻意沒修的（寫下來，不是忘了）**

- **逾時無法取消 llama.cpp 的推論。** 25 秒一到就發布原文，但那個推論還在跑、
  還占著序列工作佇列，所以緊接著的下一次聽寫要排隊。程式會記
  `the abandoned cleanup pass still occupies the work queue`。要真的修，得在
  Rust 端加取消點（callback 或 atomic flag），那是另一輪的事。
- **交接仍是單槽。** 兩段話都在鍵盤插入前發布，第一段會被第二段蓋掉；現在會在
  NSLog 說 `overwriting an unconsumed transcript`。佇列化要動 SharedStore 的資料模型。
- **鍵盤效能建議**（每個 tick 重建 UIImage、`UserDefaults(suiteName:)` 沒快取）
  還沒做——目前 0.4 秒一次的輪詢在模擬器上沒有可感覺的延遲，等真機量到再說。

---

## 附錄 B：第二輪複查（debug 子代理）之後修掉的東西（2026-10-27）

第一輪修完不代表修對。這一輪請子代理**專門找「還是會壞」的地方**（跨行程可見性、
序號、generation 守衛、生命週期、音訊 session、FFI），每一項都要指出「什麼情況下會壞、
使用者看到什麼」。以下是它找到且已修的路徑；能在模擬器上重跑的都在下表「驗證」欄寫了
結果，三項（PiP、麥克風失敗、降級階梯）在這台機器上觸發不了，只到程式碼層。

| # | 缺陷（原本會怎樣） | 修法 | 驗證 |
|---|---|---|---|
| 1 | 核心的 `join_speech` 在「非中文對中文」的邊界補一個空白，這一側直接串接；兩邊字串互為非前綴，舊 `merge` 就 `accumulated + final` → **含英文專有名詞的整句被講兩次**（「開會用 Notion 記錄開會用 Notion 記錄」） | `merge` 改成以核心回傳的完整轉錄為準（它涵蓋所有片段），這一側只在核心回空字串時才有作用 | `-OVC_MERGE_PROBE`：4 組全對，重複消失 |
| 2 | `reset()` 沒碰 spool：在錄音／整理中按清除，音檔留在 `spool/`，下次啟動被當 orphan 補辨識 → **使用者明確清掉的句子自己回來** | `reset()` 內 `spool?.discard()`、刪掉 `orphanSource`、`endBackground()` | 清除後 spool 目錄空、`s.published` 消失、重開 `recovering spool` 出現 **0 次**；「錄音中清除」這條路徑靠程式碼（`reset` 是兩條路徑共用的出口） |
| 3 | 背景到期 handler 先比對 generation 才 `endBackground()`；不符時**背景任務永遠不結束**，iOS 到期直接砍行程，而且下一次聽寫拿不到任何背景時間 | 先 `endBackground()` 再比對 | 程式碼層（路徑順序可讀） |
| 4 | `publish` 的序號由「已發布那筆 +1」推算，`clear()` 刪掉那筆 → 序號從 1 重數，鍵盤已插到第 3 句時，新句子在序號爬回 3 之前**全部不落字** | 序號搬到獨立鍵 `s.seq`，單調遞增；`clear()` 不重置它，也不重置 `consumedSeq`；取 `max(s.seq, published.seq) + 1`，順便涵蓋「舊安裝沒有這個 key」的升級路徑 | 清除後 `s.seq` 4→5、新句 5→6、鍵盤插一次（`d3-insert-after-clear.png`）；升級模擬（刪掉 `s.seq`、`published.seq=6`、`consumedSeq=6`）→ 新句 `s.seq=7`、`consumedSeq` 6→7（`d4-upgrade-insert.png`） |
| 5 | 麥克風停止／失敗一律 `keepAlive: false`，在 Mode 2 下等於關掉音訊 session → **一次失敗就把 PiP 小窗拆了**，之後每次按麥克風都跳 App | 三處（`attach`／`stop`／`fail`）改用 `keepsAudioSession`（`mode == .pip \|\| PiPController.shared.isLive`） | 程式碼層；PiP 本身待真機 |
| 6 | 補辨識與麥克風互搶：冷啟動時補辨識先跑，占住麥克風二十幾秒，使用者對著一場「其實還沒開始」的錄音講話 | 延後 1.5 秒＋`recovering`／`startAfterRecovery`／`finishRecovery()`：麥克風點擊不搶，等補辨識交付完立刻接上；補辨識期間對外是 `.transcribing`，不再謊報錄音中 | 延遲與 phase 有實測（M3 邊界 1、2）；「排隊後自動接上」只有程式碼層 |
| 7 | 降級起點固定是「偏好的模型」→ 裝 2B／1.5B／0.5B 時，第二次失敗又選回剛剛超時的 1.5B，log 還說「沒有更小的」 | 起點改成實際生效的模型（`activeName ?? preferredName`），可 2B → 1.5B → 0.5B | 程式碼層（Swift 這一側沒有測試目標；`cargo test` 測的是 Rust 的降級選擇） |

**順手採納的建議**

- 「已安裝」的判斷收緊成核心真正會載入的檔案配對（見 M5）。
- `Core.submit` / `Core.segments` 失敗各記**一次** log（輪詢每秒 4 次，不能每次都記）；
  否則「麥克風沒收到聲音」與「引擎拒絕這段音訊」在畫面上長得一樣。
- 啟動時把殘留的 `.recording/.transcribing/.refining` 復位成 `.idle`
  （detail 寫「上次的聽寫沒有完成」），否則鍵盤會顯示一顆永遠不會結束的停止鍵。
- 新的一次聽寫開始前清掉 `partial`，否則上一次的即時字幕會在新的錄音頭上出現。
- `recoverOrphan` 不再刪掉較舊的 orphan（見 M3 邊界 2）。
- `pipFreshness` 8 → 20 秒（見 M4）。

**這一輪的實測（模擬器 iPhone 17 / iOS 26.0）**

| 項目 | 結果 |
|---|---|
| `cargo test` | 88 passed / 0 failed |
| 模擬器建置 | `BUILD SUCCEEDED` |
| 真機建置（`generic/platform=iOS`） | `BUILD SUCCEEDED`（`allowBluetooth` 兩個 deprecation warning，既有） |
| 注入 `probe3.wav`（整理關） | `dictation done: 27 chars`，`s.seq` 6、`published.seq` 6 |
| 鍵盤插入 | 27 字一次，`consumedSeq` 3 → 6 |
| 清除 | `s.phase = idle`、`s.published` 消失、`s.seq` 5、spool 空，重開 0 次回收 |
| 清除後再聽寫 | 仍然落字（27 字一次），序號沒回退 |
| 升級模擬（沒有 `s.seq`，`published.seq = 6`） | 新句 `s.seq = 7`，鍵盤插一次、`consumedSeq` 7（`d4-upgrade-insert.png`） |
| `-OVC_MERGE_PROBE` | 4 組全對 |

**仍然刻意沒修的**：附錄 A 那三項（逾時不可取消、單槽交接、鍵盤效能）不變。
另外這一輪新增一項誠實記錄：**模擬器上的 Dolphin 會把英文與數字正規化成中文**
（`-OVC_ASR_LANGUAGE=en` 也不給輸出），所以「中英混排」只能靠 `merge` 探針驗規則，
不能用音檔驗整條路徑；真機的辨識結果要等 M6。

---

## 附錄 C：第三輪複查（只看前一輪修得對不對）之後修掉的東西（2026-10-27）

修完的程式碼本身也要被審。這一輪只審 `691a3c6` 這個 diff，找到的是**上一輪修法帶進來的**
兩個新問題，以及幾個順序與清理上的漏洞。

| # | 缺陷（原本會怎樣） | 修法 | 驗證 |
|---|---|---|---|
| 1 | 保留舊 orphan 之後，同一句會被插兩次：第一次被砍留下完整的 A → 補辨識寫了 B 又被砍 → 下次補 B 並發布 → 再一次啟動撿到 A **再發布一次** | 補辨識前先把選中的檔案 `claim`（改名成 `*.claimed`，`orphans()` 不再看它）。代價是「補辨識本身被砍第二次」時那句話不會交付，所以下次啟動會**明確記錄** `recovery abandoned N claimed spool(s)`，而不是默默消失 | 植兩個 orphan、2.2 秒砍掉補辨識 → 日誌 `recovery abandoned 1 claimed spool(s)`，下一次只補較舊那一份，**沒有重複句** |
| 2 | 補辨識期間對外宣稱 `.recording`：鍵盤顯示「錄音中…」、麥克風卻沒開，使用者說的話完全沒被錄，而且鍵盤的 1.5 秒退路不會啟動（它只認「不是 `.recording`」） | 補辨識改用 `.transcribing`＋「補回上次的錄音…」，`runInjected` 的內部比對也跟著用同一個 phase | 啟動後 2 秒讀共享狀態：`s.phase = transcribing`、`s.detail = 辨識中…` |
| 3 | `publish` 先刪音檔、後寫共享狀態：中間掛掉（或 App Group 不可用）就**音檔與文字都沒有** | 先 `SharedStore.publish`，再刪 spool／orphan | 程式碼層（順序） |
| 4 | `mic.start` 已經啟用音訊 session 才在 `engine.start()` 拋錯；此時 `self.mic` 還是 nil，`fail()` 的 `mic?.stop()` 不會收拾 | `fail()` 記住「有沒有 microphone」，沒有的話自己 `setActive(false)`（PiP 模式跳過） | 程式碼層 |
| 5 | 讀不回來的 orphan 永遠排在最前面（`orphans()` 取最新），每次都失敗，較舊的完整檔案永遠輪不到 | 讀取失敗／空檔時若來源在 `spool/`，直接刪掉 | 程式碼層 |
| 6 | 同一啟動可以補兩次 orphan（`onAppear` 會重跑，而舊 orphan 現在被刻意保留） | `didRecoverOrphan` 每次啟動只補一次 | 程式碼層 |
| 7 | 模型判斷不一致：`hasModels` 認 fp32 的 SenseVoice，`Core.initialize` 只認 int8 → 裝了 fp32 的機器會被改成用 Dolphin（而 Dolphin 在真實錄音上曾輸出不連貫的句子） | 兩邊都認 `model.int8.onnx`／`model.onnx` | 程式碼層 |
| 8 | `.claimed` 檔案不在 `prune` 的預算裡，每次被砍的補辨識都留一個幾 MB 的檔 | `prune` 把 `.claimed` 一起算進上限 | 程式碼層 |
| 9 | `-OVC_CLEAR` 在 3 秒後觸發，其實落在發布**之後**，驗到的不是「補辨識途中取消」 | 改成 2 秒，並用 10.5 秒的音檔讓解碼跑得夠久 | 日誌顯示清除落在 `injected` 與 `done` 之間，**沒有** `dictation done`（見 M3 邊界 3） |

**這一輪順帶量到的（同一台模擬器）**：注入 `probe7.wav` → `dictation done: 27 chars`、
`s.seq` 9→10；鍵盤插一次，`consumedSeq` = 10。清除 → `s.phase = idle`、`s.published`
消失、`s.seq` 不動、spool 空。

**另一件用「換順序」換來的風險，也寫下來**：`publish` 現在先寫共享狀態、再刪音檔。
中間（兩行之間）被砍的話，文字已經在鍵盤那一側，但音檔還在 spool 裡，下次啟動會把它當
orphan 補辨識，於是同一句再被插一次。這個窗口只有兩行、而且要在 `publish` 剛寫完時被砍，
比原本「先刪檔、後寫字」那條會**整個句子消失**的路徑好一些——但它是「重複」而不是「沒有」，
寫在這裡以免下一個人以為這條路徑是無代價的。

**仍然沒修（誠實記錄）**：補辨識若被砍第二次，那句話不會交付（`.claimed` 留在磁碟上、
日誌有記）。要救得回來，就得能分辨「這個 `.claimed` 是已交付過的副本」與「還沒交付」，
那是把單槽交接換成佇列的同一件事，留給下一輪。

---

## 附錄：最基礎五步的實測紀錄（2026-10-27）

要求是「先做最基礎版，而且真的能用」。以下五步都在模擬器 iPhone 17
（`8E73CE6B-A4D1-4268-AE3D-B75C95A5BCB8`，iOS 26.0）上跑過。

| 步 | 動作 | 佐證 | 邊界 |
|---|---|---|---|
| 1 | 按麥克風 → 錄到音 | `-OVC_RECORD` 走真麥克風路徑（AVAudioEngine → `AudioSpool`），**上一輪**驗過靜音自動停止＋publish | 本輪**未重跑**：本輪改用注入音檔，不經過麥克風路徑 |
| 2 | ASR 出字 | log：`recogniser ready` → `dictation done: 23 chars`（整理過）／27 chars（原文） | 注入檔，非現場收音 |
| 3 | 文字出現在畫面 | 截圖 `m3-trad-28s.png`：畫面顯示「今天下午三点要跟王经理开会，讨论下个季度的预算」 | 輸出是**簡體**，見下方已知缺陷 |
| 4 | 可複製、可清除 | 截圖：`複製` / `清除` 兩鍵在文字下方，狀態為「完成」；按清除後 `s.phase = idle`、`s.published` 消失、spool 空、重開 0 次回收 | 剪貼簿內容未逐一截圖；鍵盤畫面在清除後是 0 字（`d2-after-clear.png`） |
| 5 | 鍵盤把字插進**游標位置** | 截圖 `d1-insert.png` / `d3-insert-after-clear.png`：KB probe 的 TextEditor 出現 **27 字**，鍵盤上方同步顯示同一句 | TextEditor 是**本 App 的測試畫面**，不等於第三方 App；第三方在 M6 |

第 5 步是乾淨的一次插入（27 字，不是 46）——舊版 `publish` 會把 `consumed`
重設，同一句有機會被插兩次；現在每次發布帶自己的序號，鍵盤記下自己插過的序號，
所以「同一句」不可能再插第二次（重開 App 再進 probe 畫面是 0 字，已驗）。
序號另外改成單調計數器，所以「清除之後的新句子」也不會被舊的 `consumedSeq` 擋掉
（本輪實測：清除後再聽寫 → 27 字一次，見 M2 佐證）。

**已知缺陷（寫下來，不假裝沒有）**：上面第 3 步的字是**簡體**。ASR（Dolphin）
在台灣口音上輸出簡體，而**被降級到的 0.5B** 沒把字轉成繁體——即使提示詞要求、範例也示範了。
這是「降級模型的品質代價」的具體樣貌，不是兩個模型都這樣：2B 尚未在真機上驗證。
處理順序是先在真機確認 2B 的輸出，再決定是否需要在程式裡做簡繁轉換
（不靠模型，才不會隨模型大小而變）。在那之前，這條缺陷算在降級頭上。

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

# 規則層探針（不需要音檔）
xcrun simctl launch <sim> com.example.offlinevoiceassistant.ios -OVC_MERGE_PROBE
# 清除路徑（3 秒後觸發真正的「清除」動作）
xcrun simctl launch <sim> com.example.offlinevoiceassistant.ios -OVC_CLEAR
# Push（模擬器不支援，會看到退回 Mode 1 的 log）
xcrun simctl launch <sim> com.example.offlinevoiceassistant.ios -OVC_PIP_PROBE
```

讀 App Group 的狀態要用 `defaults`，不要直接讀 plist——`cfprefsd` 會給你舊快取：

```bash
G=~/Library/Developer/CoreSimulator/Devices/<sim>/data/Containers/Shared/AppGroup/<group>
xcrun simctl spawn <sim> defaults read "$G/Library/Preferences/group.com.example.offlinevoiceassistant"
```
