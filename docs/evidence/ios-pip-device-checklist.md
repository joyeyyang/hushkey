# Mode 2（PiP 零跳轉）真機驗收清單

> 這份清單存在的理由：**模擬器驗不了這件事**。
> `AVPictureInPictureController.isPictureInPictureSupported()` 在 iPhone 17 模擬器
> （iOS 26.0）回 `false`，App 會誠實退回 Mode 1 並顯示「這台裝置不支援小窗（PiP）」。
> 所以在這份清單被填完之前，專案裡沒有任何一處可以宣稱「零跳轉已驗證」。
>
> 目前狀態：**未在真機執行**（2026-10-29）。程式碼層已審視，執行期全部待驗。

## 0. 前置

| 項目 | 要求 | 怎麼確認 |
| --- | --- | --- |
| 裝置 | 支援 call-style PiP 的 iPhone／iPad（iPhone 15 Pro 已配對） | App 選 Mode 2 後不出現「不支援」訊息 |
| 建置 | 簽章建置（PiP 與 App Group 都要 entitlement） | `xcodebuild -sdk iphoneos` 後以 Xcode 安裝 |
| 模型 | ASR ＋ 任一 GGUF | App 首頁不是「還沒有可用的模型」 |
| 鍵盤 | 設定 › 一般 › 鍵盤 › 鍵盤 › 新增「Hushkey」，並開啟**允許完全取用** | 鍵盤上按鉛筆／麥克風不會顯示「請開啟允許完全取用」 |
| 模式 | 轉錄頁切到 Mode 2 | 畫面出現「小窗會在本 App 切到背景後出現。」 |

## 1. 收 log（每一個案例都要留）

```bash
# 終端機 A：跟著 App 與鍵盤的 log
log stream --style compact \
  --predicate 'subsystem == "com.example.offlinevoiceassistant.ios"' | tee /tmp/ovc-pip.log
```

要看的三行：

```
pip: start requested
pip: window is live            ← delegate 真的起來了
record request via notification ← 鍵盤的點擊走的是通知，不是 URL（＝沒有跳 App）
```

若看到 `pip: failed to start: …`，把整行留下來：最常見的三個原因是沒有
`UIBackgroundModes: audio`、audio session 沒有 active、以及裝置不支援。

## 2. 案例

每一列都要填「結果」與「證據」。**沒跑的就寫「未驗」**，不要寫「應該可以」。

### A. 小窗真的出現

1. 轉錄頁選 Mode 2。
2. 按 Home 離開 App（或切到別的城市 App）。
3. 預期：畫面出現 PiP 小窗，內容是黑底白字「準備好了」或目前聽到的字。
4. 預期 log：`pip: window is live`。

| 結果 | 證據 |
| --- | --- |
| 未驗 | |

### B. 零跳轉：在小窗活著時按鍵盤麥克風

1. 開「備忘錄」，叫出 Hushkey 鍵盤。
2. 按麥克風，說一句話。
3. 預期：**畫面停在備忘錄**，鍵盤上方出現「錄音中…」，說完後文字落在游標處。
4. 預期 log：`record request via notification`（不是 `via url`）。
5. 失敗樣態：切到 Hushkey 才開始錄音 → 就是 Mode 1 的行為，代表
   `SharedStore.pipAlive` 在鍵盤眼裡是 false（見 E）。

| 結果 | 證據 |
| --- | --- |
| 未驗 | |

### C. 小窗是即時字幕

1. 在 B 的錄音過程中看 PiP 小窗。
2. 預期：小窗每秒更新，顯示目前聽到的片段（`session.partial` 的後 60 字），
   不是靜止的「錄音中…」。
3. 預期：辨識完顯示「辨識中…」→「整理中…」→ 整理後的文字。

這一項同時驗 keep-alive：**沒有畫面更新的 PiP 小窗會被系統關掉**，所以
「小窗還在」本身就證明 1 fps 的 repaint 有跑。

| 結果 | 證據 |
| --- | --- |
| 未驗 | |

### D. 落字位置正確（第三方 App × 3）

在 **備忘錄／訊息／Safari 的輸入框**各做一次 B。預期：文字出現在游標處，
鍵盤沒有被關掉，App 沒有被切走。

| App | 結果 | 證據 |
| --- | --- | --- |
| 備忘錄 | 未驗 | |
| 訊息 | 未驗 | |
| Safari | 未驗 | |

### E. 心跳：App 被殺掉之後，麥克風不能變成死鍵

這是整個設計最容易被誤解的一條。`pipLive` 是旗標，行程被砍時 delegate 不會跑，
旗標會永遠停在 `true`；所以真正的判斷是 `pipLiveAt` 的新鮮度（20 秒）。

1. 讓 PiP 活著（A），回到備忘錄。
2. 從多工列**上滑殺掉 Hushkey**（小窗應該消失）。
3. 立刻（20 秒內）按鍵盤麥克風 → 允許它仍然相信小窗，走通知。
4. 等 20 秒以上，再按一次麥克風。
5. 預期：第 4 步**不會**出現「錄音中…」然後什麼都沒發生；1.5 秒後顯示
   「小窗沒有回應，改為開啟 App」並跳到 Hushkey。
6. 預期 log：`pip: stopped` 不一定有（被殺不會跑），重點是第二次點擊走 `via url`。

| 結果 | 證據 |
| --- | --- |
| 未驗 | |

### F. 使用者自己關掉小窗

1. PiP 活著時，按小窗上的關閉（×）。
2. 預期 log：`pip: window closed`。
3. 回 App 再選一次 Mode 2。
4. 預期 log：`pip: start requested` → 重新出現小窗（不是靜靜地什麼都不做）。

| 結果 | 證據 |
| --- | --- |
| 未驗 | |

### G. 一次失敗不能拆掉小窗

`MicCapture.stop(keepAlive:)` 與 `fail()` 在 Mode 2 下**不**deactivate audio session，
因為那會把 App 賴以維生的小窗一起關掉。

1. PiP 活著時，製造一次錄音失敗（例如在錄音中把模型檔搬走，或拒絕麥克風權限後再按）。
2. 預期：畫面出現錯誤訊息，**小窗還在**。
3. 再按一次麥克風：仍然零跳轉（不是變成每次都要跳 App）。

| 結果 | 證據 |
| --- | --- |
| 未驗 | |

### H. Mode 1 沒有被改壞

1. 切回 Mode 1。
2. 按鍵盤麥克風 → 預期跳到 Hushkey 並開始錄音（原本的行為）。
3. 預期：不會有小窗殘留（`PiPController.shared.stop()`）。

| 結果 | 證據 |
| --- | --- |
| 未驗 | |

## 3. 判定

全部 A–H 都填「通過」才能說 Mode 2 完成。任何一項失敗，先把 log 貼回
`docs/milestones.md` 的 M4／M6，再改程式——不要用「大概可以」結案。

已知的兩個設計限制（不是 bug，但驗收時會看到）：

- **小窗被系統收掉時，App 可能已經被暫停**：下一次點擊會走 1.5 秒的退回路徑，
  也就是跳一次 App。零跳轉的前提是「小窗活著」。
- **20 秒新鮮度是取捨**：主執行緒匯入模型可以卡好幾秒，太短會誤判成死亡而強迫跳 App；
  太長則被殺掉的 App 會多吞幾次點擊。目前選 20 秒，實測數字要回填在這裡。
