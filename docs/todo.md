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

## 7. 還沒做

- 語音編輯指令（「把第二段改成…」）：要新的 LLM ABI 與提示詞，最後做。
  這輪沒動，維持未完成。
- 長會議（>5 分鐘）的切段與去重尚未在真實錄音上跑過。
- 台語（Minnan）只驗過模型支援，沒有用真人錄音聽過。
