# Hushkey（HSK）iOS 版里程碑（M0–M7）

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
| M5 真機安裝與模型 | `[x]` | — |
| M6 真機實測 | `[~]` | 三項數字已有（見 M6 節）；Third-party 落字與 Mode 1/2 全流程要人工操作＋截圖 |
| M7 與 macOS 對齊 | `[~]` | 見 `## M7 — 與 macOS 對齊`，未完成的是會議模式與語音編輯 |

### 2026-10-28 這一輪

使用者回報「手機語音輸入之後 AI 沒有整理」，查出來不是模型不夠力，是**假降級**：
一次 bench 用 `DEVICECTL_CHILD_OVC_LLM_MODEL=qwen2.5-0.5b…` 指定跑小模型，
`LLMPolicy.recordIfDowngraded` 只看「誰作答」，就把那次指定記成「2B 無法執行」，
永久寫進 App Group，之後每次啟動都 `setenv` 成 0.5B。根因、修法與佐證見附錄 F。

2026-10-27 已跑完 plan／review／debug 五輪複查：review 的 12 項見附錄 A，
debug 的 7 項見附錄 B，第三輪回頭審「前兩輪修得對不對」找到的 9 項見附錄 C，
第四輪審第三輪的修法又改了 10 項見附錄 D，第五輪審第四輪的修法再改 6 項見附錄 E。
文件裡的「佐證」只寫真的跑過的，量不到的一律標成「待真機」或「程式碼層」，
不寫「應該可以」。


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
   現在它對外是 `.transcribing`（detail 先是「補回上次的錄音…」，`decode()` 立刻換成
   「辨識中…」，所以讀到的是後者）。實測（啟動後 2 秒讀共享狀態）：

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
- [x] 真機上 2B 模型的：模型載入秒數、整理耗時、峰值記憶體
- [x] 若 2B 超出背景時間或記憶體不足 → **記錄實際數字**後才降級，不是憑感覺
- [x] 降級後 0.5B 的同三項數字
- [ ] Mode 1 全流程：按麥克風 → 跳 App → 說完 → 返回 → 文字出現
- [ ] Mode 2 全流程：PiP 小窗、零跳轉、鍵盤即時字幕
- [ ] 鍵盤在第三方 App（Messages / Safari / Notes）都能落字
- [~] 上述每一項都有截圖或 log，不是「應該可以」

**實測數字（iPhone 15 Pro · A17 Pro · iOS 27.0.1 · `00008130-001630243AE8001C`）**

| 項目 | 數字 | 怎麼量的 |
|---|---|---|
| ASR 載入 | 0.45–0.52 秒 | `-OVC_DEVICE_BENCH`，`Documents/bench.json` 的 `asrLoadSeconds` |
| ASR 模型 | 228.45 MB（SenseVoice int8） | `OvcMemoryUsage.model_bytes`，載入後峰值 378.8 MB |
| 2B 整理（第二次啟動起） | 24 字 2.24 秒 · 41 字 2.91 秒，峰值 1777.1 MB | 同上，`refine[]` |
| 2B 整理（68 字，含簡→繁與守門） | 3.70 秒，峰值 1699.2 MB | `-OVC_REFINE_TEXT` |
| 2B 首次啟動 | 22.09 秒，其中 `ggml_metal_library_compile_all` 17.818 秒 | 真機 log；第二次啟動快取後同一段 0.012 秒 |
| 0.5B（備援） | 1.50 秒 · 1.06 秒，峰值 957.8 MB | 同上 |
| 端到端 `-OVC_AUDIO_FILE` | ASR → 整理 → `s.published`（seq 2、3）全通 | App Group plist |

**結論：2B 不需要降級。** 峰值 1.78 GB 在 A17 Pro 上離被殺很遠，整理 2–3 秒
也在 iOS 給背景 App 的 ~30 秒之內。0.5B 留著只是備援，不是預設。

首次啟動的 22 秒**不能當常態**：那是 Metal 函式庫要編譯，編完寫進
`Library/Caches/…/com.apple.metal/`，之後 0.012 秒。真正該注意的是
「第一次整理要等 20 秒」，而它只發生在安裝後第一次。

**這一步沒有程式碼可寫，只有量測與修正。** 量不到的項目要明確寫「量不到」，
不能寫「應該沒問題」——`docs/PROJECT.md` 第 8 節記的正是這件事：
量測工具自己壞掉時它不會失敗，它會測不到東西。

---

## M7 — 與 macOS 對齊

**為什麼需要**：使用者要的是「iOS 與 Mac 兩個系統內容一模一樣」。這件事不能靠
感覺，要靠一張表，而且**沒做的要寫沒做**——一份只列已完成項目的對照表，
正好就是「AI 沒整理」這種錯誤能活好幾個月的原因。

**2026-10-28 這一輪補上的**

| 功能 | 之前 | 現在 |
|---|---|---|
| 簡→繁（`Hans-Hant`） | 沒有 | 辨識後與整理後各一次（「下礼拜和校庆」→「下禮拜和校慶」） |
| 整理後的守門（`sanityCheck`） | 沒有 | 有：擋空回覆、斷章、洩漏提示詞、被翻走、Meta 開場 |
| 翻譯（自動／不翻／一律英文／一律繁中） | 沒有 | 有，四個模式與 macOS 同名同義 |
| 整理段數 0/1/2 | 沒有 | 有 |
| 歷史 | 沒有 | 有：搜尋、複製、分享、單筆刪除、全部清空（要確認）、每句耗時 |
| 關鍵字 | 沒有 | 有（與 macOS 同樣**不注入提示詞**，理由寫在畫面上） |
| 匯出 | 沒有 | 有：Markdown / txt / JSON + 系統分享面板 |
| 音檔匯入 | 只有 `-OVC_AUDIO_FILE` 旗標 | 有：文件選擇器，任何 AVFoundation 開得起來的格式 |
| 暫停／繼續 | 沒有 | 有；鍵盤上就有一顆，走 Darwin 通道，同一個 spool、同一個 ASR session，不是切兩段（真機已驗） |
| 五個分頁 | 只有單頁 | 轉錄／歷史／關鍵字／模型／設定，順序與 macOS 相同 |

**還沒對齊（明確清單）**

| 功能 | 為什麼還沒 | 要什麼才能做 |
|---|---|---|
| 會議模式（摘鈕／決議／待辦） | 核心的 `LLM_Summarize` 已經接好，缺的是錄音端：iOS 拿不到系統音訊，`我：／對方：` 分不出來 | ReplayKit Broadcast Upload Extension + 使用者授權；不是一個下午的事 |
| 語音編輯（改上一次送出的字） | iOS 沒有 AX，改不到別的 App 的文字；**但鍵盤改得到自己上次插入的字**（`deleteBackward` × N 再 `insertText`） | 共享通道 + 鍵盤端替換；下一輪做 |
| 貼上前確認（可編輯後才送） | 鍵盤插入是即時的，Mac 的「Enter 才貼上」在鍵盤上要另一套 UI | 同上，與語音編輯一起做 |
| 5 套紙色主題 | iOS 固定深紙色 | 純外觀；`Palette` 已經是單一來源，改起來不難 |
| SRT 匯出 | Markdown／txt／JSON 已足夠 | 會議模式有時間段之後才有意義 |
| 模型從 manifest 下載與驗證 | iOS 靠 Finder／檔案 App 放入（已寫在畫面上） | 手機上的下載器＋SHA-256 驗證；與 macOS 的 `ModelInstaller` 對齊 |

---

## 依賴關係

```
M0 ──> M1 ──> M2 ──> M3 ──> M4
                      │
                      └──> M5 ──> M6 ──> M7
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
| 1 | 保留舊 orphan 之後，同一句會被插兩次：第一次被砍留下完整的 A → 補辨識寫了 B 又被砍 → 下次補 B 並發布 → 再一次啟動撿到 A **再發布一次** | 補辨識前先把選中的檔案 `claim`（改名成 `*.claimed`，`orphans()` 不再看它）。代價是「補辨識本身被砍第二次」時那句話不會交付，所以下次啟動會**明確記錄**一行 `claimed spool(s)`（第四輪把措辭改成 `recovery left N claimed spool(s); they will not be retried`，見附錄 D） | 植兩個 orphan、2.2 秒砍掉補辨識 → 日誌 `recovery abandoned 1 claimed spool(s)`（當時的字串，第四輪改成 `recovery left …`，見附錄 D 第 8 列），下一次只補較舊那一份，**沒有重複句** |
| 2 | 補辨識期間對外宣稱 `.recording`：鍵盤顯示「錄音中…」、麥克風卻沒開，使用者說的話完全沒被錄，而且鍵盤的 1.5 秒退路不會啟動（它只認「不是 `.recording`」） | 補辨識改用 `.transcribing`＋「補回上次的錄音…」，`runInjected` 的內部比對也跟著用同一個 phase | 啟動後 2 秒讀共享狀態：`s.phase = transcribing`、`s.detail = 辨識中…`（`runInjected` 先寫「補回上次的錄音…」，`decode()` 緊接著覆寫成「辨識中…」，讀到的是後者） |
| 3 | `publish` 先刪音檔、後寫共享狀態：中間掛掉就**音檔與文字都沒有** | 先 `SharedStore.publish`，再刪 spool／orphan（代價是兩行之間被砍會重複一次，見本節末） | 程式碼層（順序） |
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

## 附錄 D：第四輪複查（審第三輪的修法）之後改掉的東西（2026-10-27）

第三輪的修法本身也被審了一次，只看 `d7bac74` 的 diff。找到的問題多半是**第三輪自己帶進來的**，
另外三項是文件寫得比程式滿。

| # | 缺陷（原本會怎樣） | 修法 | 驗證 |
|---|---|---|---|
| 1 | 認領（claim）之後、音檔讀進來之前的任何失敗（模型壞了、上一輪留著的 session），`orphanSource` 還是 nil，`fail()` 刪不到那個 `.claimed` → **那句話永久不交付，而且每次啟動再吃掉一份 spool** | `orphanSource` 改成 `reset()` 之後**同步**設定，不等解碼；`fail()` 對「音檔還沒讀進來」的已認領檔改為 `unclaim`（改名回 `.wav` 退回佇列），已經讀到音檔才刪 | 程式碼層（模擬器上造不出「引擎啟動失敗」） |
| 2 | 清除時沒有關掉 ASR session：`stop()` 只認 `.recording`，而補辨識／注入路徑是 `.transcribing` → 同一行程下一次按麥克風會被 Rust 以 `ASR session already active` 拒絕一次，訊息還是英文 | `clear()` 在「忙碌但不在錄音」時排一個 `Core.stop()`（同一條序列佇列，排在下一場聽寫之前） | 新增探針 `-OVC_AFTER_CLEAR <wav>`：清除後同行程再聽寫 → `dictation done: 27 chars`。**但拿掉修正的對照建置沒有重現失敗**——清除落在解碼階段，`decode` 自己已經 `Core.stop()`；真正的窗口只有餵音迴圈那幾十毫秒。留著是因為「清除後不該有殘留 session」不該依賴那個窗口的長度，但**不能宣稱它是實測修好的** |
| 3 | `prune` 跑在回報 abandoned **之前**：`.claimed` 是最舊、又永遠不會消失的一批，於是被靜默刪掉，「明確記錄」變成空話 | 先回報、再 `prune` | 見下方 D 組實測 |
| 4 | 補辨識自己也寫一份 spool → 補辨識被砍時，半成品變成「最新 orphan」，下次啟動解到**截斷的句子**，而完整那份被當成 abandoned | 補辨識不再寫第二份 spool（它的音檔就是它正在解的那個檔） | 砍在解碼中 → spool 只剩較舊的檔案，沒有半成品 `.wav`；下次啟動只補那一份 |
| 5 | `discardIfSpool` 把「轉換失敗」也當成壞檔刪掉，那一句就沒了（而且轉換失敗可能是暫時性的） | 拆成 `discardIfUnreadable`（連 `AVAudioFile` 都開不起來才刪）與 `removeSpool`（空檔） | 見下方 E 組實測 |
| 6 | `SenseVoice` 的判斷只要求 `.onnx`，沒有一併要求 `tokens.txt` → 裝了純 fp32 又缺 token 的 SenseVoice ＋ 一顆 Dolphin 時，會選到殘缺的 SenseVoice，載入時才失敗（模型頁卻說已安裝） | `Core.initialize` 與 `hasModels` 都要求 model 與 `tokens.txt` 成對 | 程式碼層 |
| 7 | `.claimed` 與可回收的 `.wav` 共用同一個 6 份預算，死檔會擠掉還有救的音檔 | 保留（取捨已寫進程式註解）：不共用就得有兩套上限，而目前一次啟動只補一份，6 份足夠 | — |
| 8 | abandoned 的日誌寫「those sentences were not delivered」：`publish` 之後、刪檔之前被砍也會留下 `.claimed`，那句其實**已經交付** | 改成 `recovery left N claimed spool(s); they will not be retried`（只說事實） | 見 D 組 |
| 9 | 文件把「先寫共享狀態再刪音檔」的收益寫成「或 App Group 不可用」——那句是錯的：沒有 App Group 時 `UserDefaults(suiteName:)` 仍非 nil，寫入會「成功」，接著照樣刪檔，**音檔與文字都沒有、也沒有錯誤訊號** | 文件改寫成「中間被砍」這一種情況 | — |
| 10 | 文件同時寫「對外是 `.transcribing`＋『補回上次的錄音…』」與實測到的 `s.detail = 辨識中…`，沒說哪個是哪一刻 | 文件註明：`runInjected` 先寫前者，`decode()` 立刻覆寫成後者 | — |

**這一輪的實測（模擬器 iPhone 17 / iOS 26.0）**

A. 注入 `probe11.wav` → `dictation done: 27 chars`、`s.seq` 22（重建後回歸）。
B. 清除落在補辨識期間，同一行程再聽寫（`-OVC_CLEAR` ＋ `-OVC_AFTER_CLEAR`）：

```
recovering spool wwww0021-long.wav
dictation injected: wwww0021-long.claimed
clear requested at launch
dictation requested after clear
dictation injected: probe12.wav
dictation done: 27 chars            ← 沒有 ASR session already active
```

C. 手動佈一個「補辨識被砍後留下的 `.claimed`」＋一份較舊的完整 orphan：

```
recovery left 1 claimed spool(s); they will not be retried
recovering spool ssss0017-old.wav
dictation injected: ssss0017-old.claimed
dictation done: 27 chars            ← 舊的那份照樣補回來，死檔沒有被重試
（spool 目錄結尾只剩 tttt0018-long.claimed）
```

D. 砍在補辨識的解碼途中（8 秒）：spool 目錄沒有出現半成品 `.wav`，下一次啟動只補較舊那份。

E. 把內容不是音訊的檔案當成最新 orphan：`dictation failed: 讀不到測試音…`、該檔被刪，
下一次啟動補回較舊的那份（不會每次啟動都撞同一個壞檔）。

**五輪下來的結論**：能在這台機器上重現的都修了並留了 log；不能重現的（PiP、麥克風失敗、
引擎啟動失敗、`pipLive` 新鮮度、2B 速度）都標成「程式碼層」或「待真機」，沒有寫成已驗證。

---

## 附錄 E：第五輪複查（審第四輪的修法）之後改掉的東西（2026-10-27）

第四輪修掉「認領的音檔會被吃掉」，第五輪只看那個修法。找到的兩條必修都是**第四輪自己帶進來的**：
一條把「不是認領的檔案」誤判成別人的、直接刪掉；一條讓「退回佇列」在十分鐘後失效。

| # | 缺陷（原本會怎樣） | 修法 | 驗證 |
|---|---|---|---|
| 1 | `fail()` 用**副檔名**判斷「這是我們認領的檔」。`claim` 失敗時 `recoverOrphan` 拿的是原始 `.wav`，此時引擎啟動失敗 → 走 `else` 直接刪掉，**正是這輪要救的那句話被刪**（修正前反而不會刪，因為 `orphanSource` 當時是 nil） | 改成記狀態：`orphanWasClaimed` 在 `runInjected` 同步設定，`fail()` 對「還沒讀到音檔」的一律不刪（認領過的 `unclaim` 回 `.wav`，本來就是 `.wav` 的留在原地） | 程式碼層（模擬器造不出引擎啟動失敗，見下方說明） |
| 2 | `unclaim` 用 `moveItem` 改名，**mtime 不變**。`orphans()` 只收 3–600 秒的檔，所以「退回佇列」只保證十分鐘；引擎壞更久或使用者隔天才開，那句既不補也不再被提起，最後被 `prune` 刪掉 | `unclaim` 改名後把 mtime 蓋成現在（「它現在才變成可用」是事實） | 見下方 C 組：15 分鐘前的檔案**不會**被補；`touch` 成現在後立刻補回 27 字 |
| 3 | `discardIfUnreadable` 只看「`AVAudioFile` 開不開得起來」，開不起來就刪——但被砍的 spool 可能標頭短、資料完整（`salvageRawWAV` 救得回來） | 刪之前先試 `salvageRawWAV`，救得回樣本就不刪 | 程式碼層 |
| 4 | 補辨識失敗時，使用者看到「讀不到**測試音**」「**測試音**是空的」——那句話不是測試音 | 依 `isRecovery` 換成「上次的錄音」 | 程式碼層（模擬器的壞檔案例仍是測試音路徑） |
| 5 | `Core.initialize` 對 Dolphin 只驗 model 不驗 `tokens.txt`，與 `hasModels`、`state.rs` 的「成對」不一致 | 兩者都要求成對 | 程式碼層（無使用者可見差異，兩條路最後都是同一個載入失敗） |
| 6 | `runInjected` 在 `work` 佇列上直接讀 `@MainActor` 的 `recovering`；`clear()` 可在餵音途中改它，於是白建一份 spool 再丟掉，Swift 6 嚴格併發也會擋 | 進 `work.async` 之前先抓成 `let isRecovery` | 程式碼層 |

**另一件被指出、但選擇保留的（這次寫進文件，不再只是「知道就好」）**：清除時 `reset()` 會刪掉
**正在補辨識的那份 `.claimed`**，也就是「清除 = 連上一句已經在補的句子一起丟」。這與 `fail()`
刻意保留 `.claimed` 的立場相反，但兩者面對的意圖不同：`fail()` 是「不要因為不相干的錯誤弄丟」，
`clear()` 是「使用者說不要這一點了」。下方 B 組的 log 正好看到這個行為。

**這一輪的實測（模擬器 iPhone 17 / iOS 26.0，`cargo test` 88 項全綠）**

A. 注入 `probe13.wav` → `dictation done: 27 chars`、`s.seq` 24、spool 空；改完 `unclaim`
的錯誤處理後再用最終建置跑一次 `probe15.wav` → 同樣 27 字、`s.seq` 27、spool 空。

B. `-OVC_CLEAR` ＋ `-OVC_AFTER_CLEAR`，並預先放一份死 `.claimed` 與一份較舊的完整 orphan：

```
recovery left 1 claimed spool(s); they will not be retried
recovering spool bbbb0026-long.wav; 1 older one(s) kept
dictation injected: bbbb0026-long.claimed
clear requested at launch            ← 落在補辨識途中
dictation requested after clear
dictation injected: probe14.wav
dictation done: 27 chars             ← 沒有 ASR session already active
（spool 結尾：aaaa0025-old.wav、cccc0027-dead.claimed —— 死檔留著、較舊的完整 orphan 還在）
```

C. `orphans()` 的 600 秒窗口（第 2 列的前提）：

```
C1  15 分鐘前的 dddd0028-stale.wav → 沒有任何 recovering 這行，檔案留在 spool
C2  touch 成現在 → recovering spool dddd0028-stale.wav → dictation done: 27 chars
```

**第 1 列只能算程式碼層，原因照實寫**：想用「把 ASR 模型 `chmod 000`（檔案還在、但讀不到）」
製造引擎啟動失敗，`hasModels` 仍回 true，但 App 在模型載入階段就**直接消失**——沒有 crash
report、日誌停在 `llm model:` 那一行，連補辨識都還沒開始。所以這條分支沒有可重現的觀測，
只有「`fail()` 讀的是狀態不是副檔名」這個程式碼事實。要真的驗，得等真機上出現一次載入失敗。

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
cargo test --manifest-path rust/core_engine/Cargo.toml

# 模擬器 slice
SHERPA_ONNX_DIR="$PWD/rust/core_engine/vendor/ios/sim" \
  cargo build --manifest-path rust/core_engine/Cargo.toml --target aarch64-apple-ios-sim --release
cp -f rust/core_engine/target/aarch64-apple-ios-sim/release/liboffline_voice_core.a ios/ios_app/vendor/sim/

# 真機 slice
SHERPA_ONNX_DIR="$PWD/rust/core_engine/vendor/ios/device" \
  cargo build --manifest-path rust/core_engine/Cargo.toml --target aarch64-apple-ios --release
cp -f rust/core_engine/target/aarch64-apple-ios/release/liboffline_voice_core.a ios/ios_app/vendor/device/

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
# 清除路徑（2 秒後觸發真正的「清除」動作）
xcrun simctl launch <sim> com.example.offlinevoiceassistant.ios -OVC_CLEAR
# 清除後在同一行程再聽寫（看取消有沒有留下沒關的 ASR session）
# 音檔要給絕對路徑：相對路徑會被解析成 /，探針就靜默不跑了
xcrun simctl launch <sim> com.example.offlinevoiceassistant.ios \
  -OVC_CLEAR -OVC_AFTER_CLEAR /abs/path/to.wav
# Push（模擬器不支援，會看到退回 Mode 1 的 log）
xcrun simctl launch <sim> com.example.offlinevoiceassistant.ios -OVC_PIP_PROBE
```

真機上的純文字整理探針（不需要麥克風，不寫入任何共享狀態；會印在
`devicectl --console` 上，同時寫進 `Documents/refine.json`）：

```bash
xcrun devicectl device process launch --console --terminate-existing \
  --device 0E8DDA9B-F778-5062-B0E5-33D3BBF7706A \
  com.example.offlinevoiceassistant.ios \
  -OVC_REFINE_TEXT "呃，我们明天我们班来开个会，就是。我们是。不是下礼拜和校庆嘛？"
# 輸出在 OVC_REFINE_BEGIN … OVC_REFINE_END 之間：
#   requestedModel（應該被叫的那一份）/ servedModel（實際作答的）
#   raw（模型原始輸出）/ traditional（再正規化之後）/ seconds / peakRSSMB
```

清除假降級（App Group 不會被重裝清掉，所以需要這個開關；模型頁也有同一顆按鈕）：

```bash
xcrun devicectl device process launch --console --terminate-existing \
  --device 0E8DDA9B-F778-5062-B0E5-33D3BBF7706A \
  com.example.offlinevoiceassistant.ios -OVC_LLM_RESET
```

裝到真機**不會**清空 `Documents/`：模型與 App Group 都留著。
`devicectl device info files` 可以列出容器內容（`--subdirectory` 會回 error 3，
只能列根目錄，用 grep 過濾）。

清 spool 目錄時不要用 `rm -f "$G/spool/"*.claimed`：zsh 在沒有任何符合的檔案時會讓**整行**失敗
（連前面的 `*.wav` 都不會刪），於是你會看到上一個測試留下的檔案，誤以為程式沒清。改用：

```bash
find "$G/spool" -name '*.wav' -delete; find "$G/spool" -name '*.claimed' -delete
```

讀 App Group 的狀態要用 `defaults`，不要直接讀 plist——`cfprefsd` 會給你舊快取：

```bash
G=~/Library/Developer/CoreSimulator/Devices/<sim>/data/Containers/Shared/AppGroup/<group>
xcrun simctl spawn <sim> defaults read "$G/Library/Preferences/group.com.example.offlinevoiceassistant"
```

---

## 附錄 F：假降級——「AI 沒有整理」的根因（2026-10-28）

### 症狀

使用者說「手機語音輸入之後 AI 沒有整理」。裝置上的證據是這樣：

```
s.detail  = 已整理 · 靜音
s.published.text = 呃，我們明天我們班來開個會，就是。我們是。不是下礼拜和校庆嘛？…
```

三件事同時不對：

1. 78 字、口頭禪「呃」「就是。」原封不動 → 根本沒整理
2. 「我們」「開會」是繁體，「下礼拜」「校庆」是簡體 → 繁簡混雜
3. `s.detail` 卻寫著「已整理」——狀態沒有說謊，整理**跑過了**，只是跑的是 0.5B

### 根因（不是猜的，是 App Group 裡讀出來的）

```json
"llmDowngrade": {
  "from": "Qwen3.5-2B-Q4_K_M.gguf",
  "to":   "qwen2.5-0.5b-instruct-q4_k_m.gguf",
  "reason": "整理時 Qwen3.5-2B-Q4_K_M.gguf 無法執行，改用 qwen2.5-0.5b-instruct-q4_k_m.gguf",
  "at": 814813160.492318
}
```

`reason` 說「2B 無法執行」，但那句話是**推論出來的，不是觀察到的**。
當時在跑 M6 量測，bench 用 `DEVICECTL_CHILD_OVC_LLM_MODEL=qwen2.5-0.5b…`
**指定**跑小模型。舊的 `recordIfDowngraded` 只比對「誰作答」：

```swift
guard !served.isEmpty, served != preferredName else { return false }   // 只看 served
```

served 是 0.5B、preferred 是 2B → 記成降級。於是：

- 寫進 App Group（**重裝 App 不會清掉 App Group**）
- 之後每次啟動 `LLMPolicy.apply()` 都 `setenv("OVC_LLM_MODEL", "qwen2.5-0.5b…")`
- 真機聽寫從此固定跑 0.5B，2B 一次都沒被叫過

一個量測用的環境變數，變成了一台裝置上永久的產品設定。

### 修法（兩層，都是「先把事實查清楚」）

1. **`LLMPolicy.requestedName`**：新增「引擎這次被叫用哪一份」的計算——
   已記錄的降級 → 啟動時帶的 `OVC_LLM_MODEL` → manifest 預設。
2. **`recordIfDowngraded` 先問「有沒有被要求用大的」**：

```swift
guard requestedName == preferredName else {
    Diagnostics.log.notice("served … because it was requested, not as a fallback")
    return false
}
```

   被指定使用的模型**不算降級**，只記一行 notice。這才是「降級」（asked for 2B,
   got 0.5B）與「指定」（asked for 0.5B, got 0.5B）的分界。
3. **`-OVC_LLM_RESET`** 與模型頁的「重新嘗試大模型」：App Group 活得比 App 久，
   所以需要一個不靠 UI 也能按的還原開關。

### 佐證

- 清掉之後重讀 App Group：`llmDowngrade` 這個 key 不見了（其餘狀態保留）
- 規則層（macOS 上編譯 `TextScript` + `TextRules` 直接餵測資）：

```
A_traditional   : 呃，我們明天我們班來開個會，就是。我們是。不是下禮拜和校慶嘛？那我們可能要開個會
A_leftSimplified: []
B_good_ok       : true      （正常整理結果 → 放行）
C_leaked_ok     : false | echoed the instructions: 不要摘要
D_translated_away_ok: false | no Chinese left in the output
E_english_src_ok: true      （英文聽寫不會被當成「被翻走」）
F_empty_ok      : false
G_meta_ok       : false     （「以下是整理後的內容：」被擋）
H_tiny_ok       : false     （只剩 1/5 長度，判定為改寫成別的東西）
```

- 真機 `-OVC_REFINE_TEXT`（iPhone 15 Pro，使用者回報的那一句原文）：

```json
{
  "recordedDowngrade": null,
  "requestedModel": "Qwen3.5-2B-Q4_K_M.gguf",
  "servedModel":    "Qwen3.5-2B-Q4_K_M.gguf",
  "inputChars": 68,
  "inputTraditional": "呃，我們明天我們班來開個會，就是。我們是。不是下禮拜和校慶嘛？…",
  "raw":         "明天我们班来开个会，讨论校庆要卖什么东西及需要准备的活動",
  "traditional": "明天我們班來開個會，討論校慶要賣什麼東西及需要準備的活動",
  "seconds": 3.70,
  "peakRSSMB": 1699.2
}
```

  三件事同時被證明：

  1. **跑的是 2B**（`requestedModel == servedModel`，`recordedDowngrade` 已清空）
  2. **真的整理了**：68 字 → 26 字，「呃」「就是。」「我們是。」與整段重複全部消失，
     問句濃縮成「要討論……」的敘述
  3. **`raw` 是簡體**（「开个会」「校庆」）而 `traditional` 沒有——中間那個
     `Hans-Hant` 不是裝飾，沒有它鍵盤拿到的就是半繁半簡，也就是使用者看到的那個樣子

- 端到端（同一支手機、`-OVC_AUDIO_FILE probe.wav`，App Group 讀回來）：

```
s.detail = 已整理 · 測試音
s.published.text = 提醒我明天下午兩點帶合約去見陳總，順便問他上個月的發票處理好了沒有
llmDowngrade = (不存在)      llmPreferredSucceeded = true
```

  同一段音檔在修好之前產出的是「提醒我明天下午两点带合约去见陈总」——
  簡體、且幾乎沒有整理。現在是繁體、補了連接詞、去掉贅字。


### 學到的（寫下來免得再犯）

**量測用的覆寫不可以進入產品狀態。** `DEVICECTL_CHILD_*` 是量測工具，
`LLMPolicy` 是產品記憶；兩者中間原本只隔一個「誰作答」的比較。
任何「把觀察寫成持久狀態」的地方，都要能分開「我要求的」與「我得到的」。

---

## 附錄 G：鍵盤拿掉字母鍵、整理改成正式語域、HUD 重疊（2026-10-28）

### G.1 iOS 鍵盤不再有 QWERTY

使用者的理由就是最好的規格：「有實體英文鍵盤的話，跟我直接打英文也沒有區別」。

- `VoiceBar` 現在是整個鍵盤：即時字幕（兩行）在上，下面一列
  `🌐 ｜ ⧉ 複製 ｜ ⏸ 暫停 ｜ 🎤 麥克風`，高度 126 pt。
- **🌐 不是裝飾**：那是離開這個鍵盤、回到使用者自己鍵盤的唯一方法。拿掉字母鍵
  卻留下它，會做出一把出不去的鍵盤。
- 暫停／繼續走 `SharedStore.requestPause()`／`requestResume()`（Darwin notification），
  和 Mode 2 的錄音請求同一條通道——鍵盤沒有麥克風，每個麥克風決定都是給 App 的訊息。
  App 用 `DictationController.init` 訂閱（不是某個畫面的 `onAppear`：錄音活得比畫面久，
  Mode 1／Mode 2 的重點就是 App 在背景時按得到）。按下去 1.2 秒內狀態沒動就在鍵盤上說
  「App 沒有回應」，而不是留一顆看起來有效的按鈕。
- `-OVC_KB_PROBE` 的探針畫面現在把真正的 `VoiceBar` 畫出來（`project.yml` 把
  `Sources/Keyboard/VoiceBar.swift` 也加進 App target），所以版面可以在機器上截圖檢查，
  不必在手機上才發現字幕被裁掉。

### G.2 整理要更正式

見 `docs/PROJECT.md` §5.5：提示詞第一段改成語域規則＋列舉，few-shot 答案跟著改，
`instructionPhrases` 兩平台同步加三句。Rust 核心重編（iOS device／sim 與 macOS）。

### G.3 macOS HUD：狀態列畫在麥克風上

見 `docs/PROJECT.md` §5.6。offline 截圖集多一張
`<theme>-dictation-partial.png`——那是唯一會把兩個東西放進波形格子的形狀，
也就是 bug 的形狀。`dictation-processing.png` 同時驗到「圖示與狀態列同時在畫面上」。

重跑：

```bash
OVC_SELFTEST_UI=/tmp/ovc-hud OVC_SELFTEST_UI_THEME=paper,night \
  dist/OfflineVoiceAssistant.app/Contents/MacOS/OfflineVoiceAssistant
# → /tmp/ovc-hud/paper-dictation-partial.png 等 5 張 × 2 主題
```

### G.4 真機驗證（2026-10-28，iPhone 15 Pro）

`-OVC_REFINE_TEXT`（同一句使用者回報的原文，修改提示詞之後）：

```json
{
  "requestedModel": "Qwen3.5-2B-Q4_K_M.gguf",
  "servedModel":    "Qwen3.5-2B-Q4_K_M.gguf",
  "raw":         "明天我们班将召开会议，议题为校庆相关事项。会议旨在讨论校庆期间需销售的物品及所需准备的各类活动",
  "traditional": "明天我們班將召開會議，議題為校慶相關事項。會議旨在討論校慶期間需銷售的物品及所需準備的各類活動",
  "seconds": 4.11,
  "peakRSSMB": 1746.7
}
```

對照修改前（附錄 F）：

| | 修改前 | 修改後 |
|---|---|---|
| 整理結果 | 明天我們班來開個會，討論校慶要賣什麼東西及需要準備的活動 | 明天我們班將召開會議，議題為校慶相關事項。會議旨在討論校慶期間需銷售的物品及所需準備的各類活動 |

「呃」「就是。」「我們是。」與整段重複都還在消失之列，差別是留下來的那一句現在是書面語。
`raw` 仍是簡體（「将召开会议」「议题」），`traditional` 不是——`Hans-Hant` 這一步照樣在做工。

`-OVC_PAUSE_PROBE`（鍵盤兩顆按鈕用的同一條 Darwin 通道，計時器代按）：

```
before pause  sharedPaused false  controllerPaused false  phase recording
after pause   sharedPaused true   controllerPaused true   phase recording
after resume  sharedPaused false  controllerPaused false  phase recording
after stop    sharedPaused false  controllerPaused false  phase done
published     「我將繼續交五家店」  detail 已整理
```

四件事被證明：通知跨得過行程、暫停不會結束這一句（`phase` 一直是 `recording`）、
恢復之後狀態回得來、暫停過的聽寫仍然只發布一次而且真的整理過。

---

## 附錄 H：iOS 錄音鈕永久失效（2026-10-28）

### H.1 根因不是麥克風，而是「請求會消失」與「busy 永不結束」

鍵盤的麥克風不能自己錄音（iOS 在麥克風權限前就擋掉 App Extension 的 CoreMedia），
所以按鍵必須讓 containing App 開始錄音。舊路徑有兩個各自會致命的問題：

1. `extensionContext.open()` 的 completion 被拿來猜 App 是否開著。iOS 在 containing App
   已經 resident 時會拒絕 open；`false` 的意思是「沒有切到 App」，**不是**「App 沒開」。
   舊程式因此丟掉整個請求。
2. 就算 URL 到了，`.transcribing` 沒有期限。`Core.stop()` 若不回來，phase 永遠是
   `.transcribing`，而錄音鈕對所有 busy phase（錄音除外）都是 disabled。之後每次按
   麥克風都走 `start()` 的 busy guard，舊版又靜默 `return`，於是看起來就是永久壞掉。

熱啟動還有第三個 race：App 啟動後 1.5 秒才補回上一輪的 orphan audio；若這段時間
鍵盤已送出新的錄音請求，補回會先占住唯一的 recogniser session，把新請求擋在後面。

### H.2 修法

- **A1：錄音請求改成持久訊號。** 鍵盤先在 App Group 寫入單調遞增的
  `s.recordRequest` 與 `s.recordRequestAt`，再發 Darwin notification。App 以
  `consumeRecordRequest()` 吃掉已處理序號，所以 URL／Darwin／activation 三個通道
  即使同時到，也只會啟動一次錄音。
- **A2：URL 不再被 `modelsReady` 靜默丟棄。** 三通道統一進
  `handleRecordRequest(channel:freshOnly:)`；先切到「轉錄」分頁。沒有模型時顯示
  「先在這一頁裝好模型」，不再假裝沒發生。
- **A3：新的錄音請求優先於 orphan recovery。** launch／active 這兩個未被提示的通道
  只認 120 秒內的新請求；`prepare()` 的 1.5 秒 recovery 守門也檢查 fresh request。
- **A4：每一段 busy 都有期限與出口。**
  - `.transcribing` 的靜默上限是 25 秒；有進度就 renew，長音檔匯入不會被砍。
  - 逾時且已有文字就 publish；沒有文字就 fail，兩者都離開 busy。
  - `Core.stop()` 的錯誤會被接住並記錄，不再被 `try?` 吞掉。
  - recovery 另有 60 秒保底，超時 `fail(...)` 並放行 `recovering`。
  - `start()` 遇到 busy 不再沉默：依序說明「上一句逾時」「正在補回上一次錄音」
    或「上一句還在處理」。

### H.3 故障注入與修好後的實測

故障入口刻意只有啟動參數：`-OVC_HANG_DECODE` 讓 decode 永不完成，
`-OVC_STUCK_PROBE` 每兩秒記一次 phase，最後代替使用者按一次麥克風。修前同一路徑
47 秒都停在 `.transcribing`，錄音鈕 disabled；修後同一路徑的 `stuck-probe.json` 是：

```json
{
  "leftTranscribing": true,
  "phaseBeforePress": "failed",
  "pressWasActedOn": true,
  "finalPhase": "recording",
  "finalButtonDisabled": false,
  "finalError": ""
}
```

時間線也對：6.24–24.97 秒仍是 `.transcribing`；27.06 秒逾時後 phase 變 `failed`、
按鈕 enabled；27.08 秒模擬器上的按鈕動作被接受，phase 變 `recording`。截圖：
`docs/evidence/ios-stuck-after-fix.png`。

App Group 持久請求的 activation 通道（App 先開著，再把 Hushkey 切到背景、寫入 request、
重啟 `cfprefsd`、切回 Hushkey）：

```text
record request via active
dictation started
s.recordRequest = 46
s.recordRequestConsumed = 46
```

`consumed` 追上 `request` 表示這次確實被 App 處理，不是按完就消失。畫面也停在
「轉錄」分頁；截圖：`docs/evidence/ios-record-request-via-active.png`。

A3 的競爭則用「orphan spool ＋ fresh request」一起驗：啟動後 log 是
`record request via launch` → `dictation started`，**沒有** `recovering spool`；
預先種的 `.wav` 仍是 `.wav`，沒有被 recovery 改成 `.claimed`。也就是新的熱啟動
錄音請求沒有被上一輪音檔搶走。

### H.4 建置、測試與證據邊界

| 檢查 | 真實結果 |
|---|---|
| `cargo test --manifest-path rust/core_engine/Cargo.toml` | `88 passed; 0 failed`；另有 `ffi_lifecycle_and_error_paths` 1/1 通過 |
| iOS simulator Debug build | `** BUILD SUCCEEDED **` |
| iOS generic device Debug build | `** BUILD SUCCEEDED **`（簽署 team `7S48J3H2N2`） |
| StuckProbe 故障注入 | 修前永久卡住；修後 `leftTranscribing=true`、按鈕可按、press 被接受 |
| activation 持久請求 | `record request via active`，序號被 consume，轉錄分頁開始錄音 |
| fresh request 對 orphan recovery | 新請求先開始；沒有 recovery log，spool 未被 claim |

證據邊界要說清楚：

- **鍵盤擴充本身無法用腳本點擊。** 模擬器不能安裝／操作這個 custom keyboard，
  所以鍵盤側以完整 source path、兩端 build 與 App Group 持久請求的整合測試佐證；
  真正在第三方 App 裡按麥克風仍要真機人工測一次。
- 模擬器麥克風不可靠；這輪驗的是 phase、序號、通道與按鈕狀態，不是實際語音品質。
- Rust 核心每個 C 入口共用同一把全域 mutex。25 秒逾時能**放行 UI**，但不能取消
  已在 Rust 裡卡住的 `Core.stop()`；那把鎖仍可能讓下一個核心呼叫排隊。訊息已明說
  「把 App 關掉再開一次」。要真正取消推論，必須在 Rust 端加取消點，這是另一輪工作。

## 附錄 I：修改提示詞——「改哪一段、怎麼改」（2026-10-28）

### I.1 這是第二次處理，不是「AI 整理」的一部分

一句話進來的流程有兩段，而且刻意分成兩段：

| | 什麼時候跑 | 誰決定內容 | 核心入口 |
|---|---|---|---|
| AI 整理 | 每句都跑（可關） | `REFINE_SYSTEM`：去贅字、加標點 | `LLM_RefineText*` |
| 修改提示詞 | 使用者按「執行修改」才跑 | **使用者的那一句話** | `LLM_EditText` |

合併會讓其中一個去做另一個的事：整理沒有「第 2 行」的概念，修改則不該自己去猜
要不要補標點。所以提示詞、系統指令、入口都分開，只共用底層的生成函式
（`generate`）與模型管理。

### I.2 提示詞與原文在核心裡是兩塊，不是串在一起

`rust/core_engine/src/llm.rs::edit_prompt` 的形狀是：

```text
<EDIT_SYSTEM>…使用者的訊息裡，第一行是指令，空一行之後才是要改的文字。
<|im_start|>user
第2點改成禮拜五下午兩點        ← 修改的提示詞（第一行）
                                 ← 空行
1. 明天下午三點跟小林開會        ← 原文，由核心自己編號
2. 討論第四季時程
3. 地點還沒確定
```

新增測試 `llm::tests::the_edit_instruction_is_not_part_of_the_draft` 直接驗這件事：
指令在整份 prompt 只出現一次、位於第一行、空行之後的本文不含指令、本文從 `1. ` 開始。

### I.3 三種區域都真的到核心，不是 UI 裝飾

| 區域 | 送給核心的指令 | 核心做的事 | 為什麼不會誤改別行 |
|---|---|---|---|
| 整段 | 原樣 | `locate_edit_target` 找不到位置 → 整份改寫 | 轉換型指令（改短）走這條 |
| 第 N 行 | `第{N}點` + 原樣 | `locate_by_position` → `edit_one_line` | 行號是核心自己數的，不是 UI 數的 |
| 選取範圍 | 原樣 | 把選取切片**當成整段**送進去，答案 splice 回原字串 | 沒選到的字根本沒進 prompt |

UI 的 `第 N 行` 用阿拉伯數字（`第2點`），核心的 digit 分支接受它；麥克風講的
`第二點` 由 `chinese_position` 處理。兩條路到同一行，測試
`llm::tests::a_prefixed_line_number_locates_that_line` 兩種都驗。
UI 的行數預覽（`PromptEditRegion.lines` / `PromptEdit.lines`）刻意照核心
`numbered_items` 的規則（去空行、去項目符號、去既有編號），所以「第 3 行」在畫面上
和核心眼裡是同一行；macOS 有 7 個單元測試釘住這件事。

### I.4 真實輸出對照（`voiceinput --edit`，worker `rust/core_engine/target/release/ovc-llm-worker`）

原文（3 行）：

```text
明天下午三點跟小林開會
討論第四季時程
地點還沒確定
```

**同一段原文，不同修改提示詞 → 輸出不同：**

```text
--- 第2點改成禮拜五下午兩點
明天下午三點跟小林開會
禮拜五下午兩點
地點還沒確定

--- 第2點刪掉
明天下午三點跟小林開會
地點還沒確定

--- 第2點改短一點
明天下午三點跟小林開會
討論第四季
地點還沒確定
```

**同一個修改提示詞，不同區域 → 影響範圍不同：**

```text
--- 改成大衛拜訪 --region line:1
大衛拜訪
討論第四季時程
地點還沒確定

--- 改成大衛拜訪 --region line:2
明天下午三點跟小林開會
大衛拜訪
地點還沒確定

--- 改成大衛拜訪 --region line:3
明天下午三點跟小林開會
討論第四季時程
大衛拜訪
```

**選取範圍只動選到的那幾個字：**

```text
--- 把三點改成四點 --region selection --select 0:11
明天下午四點跟小林開會
討論第四季時程
地點還沒確定

--- 把時程改成禮拜五 --region selection --select 12:19
明天下午三點跟小林開會
討論第四季禮拜五
地點還沒確定
```

### I.5 已知限制：整段＋轉換型指令在 2B 上不穩

```text
--- 改短一點（region 預設 whole）
voiceinput: could not apply the edit (no usable result)
```

模型把原文原樣還回來，核心判定「沒有可用結果」而拒絕——這是既有、已量測過的
限制，不是這次改壞的。App 的錯誤訊息因此直接引導使用者把範圍指成「第 N 行」或
選取起來（同一句 `改短一點` 指到第 2 行就成功，見 I.4）。指錯行比重寫整份安全。

### I.6 改完的文字不自動送進鍵盤

`SharedStore.publish` 會給新序號，鍵盤看到新序號會**再插入一次**——使用者會得到
「原文 + 改好的版本」兩段。所以 `replaceTranscript` 只更新畫面上的句子與歷史，
帶回原本輸入框的方式是按「複製」。要讓鍵盤替換已插入的字，是另一個功能（鍵盤得
記得自己插了什麼、游標在哪），這輪不做。

### I.7 建置與測試

| 檢查 | 真實結果 |
|---|---|
| `cargo test --manifest-path rust/core_engine/Cargo.toml --lib` | `90 passed; 0 failed`（含新增 2 個 edit 測試） |
| `swift test`（macOS） | `Executed 17 tests, with 0 failures`（含新增 `PromptEditRegionTests` 7 個） |
| iOS simulator Debug build | `** BUILD SUCCEEDED **` |
| iOS 畫面 | `docs/evidence/ios-prompt-edit.png`：修改提示詞輸入框、執行修改鈕、整段／選取範圍／第 1 行 |

證據邊界：模擬器沒有 LLM 模型，所以 iOS 的**畫面與建置**是在模擬器驗的；核心行為
（提示詞分離、三種區域）是在同一份 Rust 核心上以 `voiceinput` 與 `edit_batch` 量的。
iOS 走的是 in-process 的 `LLM_EditText`、macOS 走 worker，兩者是同一個 C ABI 函式，
但「在 iPhone 上按下去」仍要真機人工測一次。

## 附錄 J：Xcode 的六類警告（2026-10-28）

使用者貼的清單有五類（其中「物件檔版本」那類會噴幾百行，一行一個 object）：

| 警告 | 根因 | 修法 |
|---|---|---|
| Update to recommended settings | 專案的 `LastUpgradeCheck` 停在舊版 Xcode | `project.yml` 加 `attributes: LastUpgradeCheck: "2650"`（Xcode 26.5） |
| All interface orientations must be supported unless the app requires full screen | iPad 多工要求四個方向，或宣告 `UIRequiresFullScreen`；原本只有 iPhone 的直向 | `Info.plist` 加 `UISupportedInterfaceOrientations~ipad` 四方向。**不**宣告 full screen：Slide Over／Split View 正是它被拿來用的方式 |
| `was built for newer 'iOS' version (26.5) than being linked (17.0)` ×N | 核心靜態庫的 object 是 clang 用 SDK 預設（26.5）編的，App 卻 link 17.0 | `IPHONEOS_DEPLOYMENT_TARGET=17.0` 重編兩個 slice（cc 與 cmake 都讀這個變數），並寫進 `scripts/build_ios.sh`；`build.rs` 加 `rerun-if-env-changed`，否則改了也不會重編 |
| `'allowBluetooth' was deprecated in iOS 8.0` | 舊名 | `.allowBluetooth` → `.allowBluetoothHFP`（`Core.swift`、`PiPController.swift`） |
| `Add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'AVFAudio'` | SDK 把 AVFAudio 的型別標成 non-Sendable | `@preconcurrency import AVFoundation` |
| `Call to main actor-isolated … in a synchronous nonisolated context` 等 13 條 | `@MainActor` 類別裡的 `static` 輔助函式被背景佇列呼叫；`Timer` 閉包是 `@Sendable`；`AVAudioConverter` 的 block 也是 | 四個純函式標 `nonisolated`（`merge`／`readMono16k`／`discardIfUnreadable`／`removeSpool`，連帶 `isSpool`、`salvageRawWAV`）；三個 Timer 閉包用 `MainActor.assumeIsolated`（它們本來就在 main run loop）；`AVAudioPCMBuffer` 用 `nonisolated(unsafe) let` 帶進同步呼叫的 block，並在註解寫明為什麼安全 |

驗證方式是把 derived data 清空重編，數 `warning:` 的種類，而不是「看起來沒有」：

```text
$ xcodebuild … -sdk iphonesimulator … -derivedDataPath build-check build
exit=0
2
   2 Metadata extraction skipped. No AppIntents.framework dependency found.
** BUILD SUCCEEDED **

$ xcodebuild … -sdk iphoneos … -derivedDataPath build-device-check CODE_SIGNING_ALLOWED=NO build
exit=0
2
   2 Metadata extraction skipped. No AppIntents.framework dependency found.
** BUILD SUCCEEDED **
```

剩下那 2 行是 `appintentsmetadataprocessor` 在沒有 AppIntents 依賴時的固定訊息，
來自工具鏈、不是這個專案的程式碼，也沒有 build setting 可以關。

重編後的 object 確認（`vtool -show-build`）：

```text
sim:    platform IOSSIMULATOR   minos 17.0
device: platform IOS            minos 17.0
shim:   platform IOS            minos 17.0
```

### I.8 區域改成 SegmentedControl，並把「不同區域→不同輸出」變成回歸測試

三段的選擇用 `Picker(.segmented)`（整段／第 N 行／選取範圍）；行號不進 selection 的
識別值，否則 stepper 每按一下整個 picker 會重建。`SelectableTranscript` 也從
`PromptEditPanel.swift` 拆成自己的檔案。

`tests/edit_expected.tsv` 從 11 筆增加到 15 筆，新增的 4 筆是多行原文：

```text
第1點改成大衛拜訪   → 大衛拜訪 | 討論第四季時程 | 地點還沒確定
第3點改成大衛拜訪   → 明天下午三點跟小林開會 | 討論第四季時程 | 大衛拜訪
第2點改短一點       → 明天下午三點跟小林開會 | 討論第四季 | 地點還沒確定
第2點刪掉           → 明天下午三點跟小林開會 | 地點還沒確定
```

前兩筆是「同一個指令、不同區域」，後兩筆是「同一個區域、不同指令」——這正是
`scripts/verify.sh` 現在會擋的兩件事（`=== 15/15 right`）。TSV 是逐行的，所以
`edit_batch` 新增 `\n` 轉義，多行原文才寫得進一列。

```text
=== 15/15 changed
=== 15/15 right
```
