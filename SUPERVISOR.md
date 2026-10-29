## 2026-10-20T01:03:49+0800 查核

> 查核對象：`1e846ed`、`985e939`、`45a7f47`、`6ea26b9`（HEAD = `6ea26b9`）。
> 查核者：獨立監督者。未執行 `cargo build` / `cargo test` / `xcodebuild`；只跑唯讀指令。
> 未修改任何專案檔案（`SUPERVISOR.md` 本身除外），未 `git add` / `git commit`。

### 0. 查核基準狀態（務必先讀）

本輪查核期間，主要 agent **正在同一個工作目錄裡平行進行大幅改寫**，所以「工作區是否乾淨」有兩個不同的答案，兩者都記錄在案：

- 00:45–00:47（我第一次跑 `git status`）：工作區**乾淨**，`HEAD = 6ea26b9`。
- 01:00:43 / 01:03:49（我最後一次跑 `git status`）：工作區**已不乾淨**——5 個已追蹤檔被修改、9 個未追蹤新檔（見證據 1.2）。

因此下面所有針對 Rust/Swift 原始碼的結論，都是針對 **HEAD（`6ea26b9`）的已提交版本**。我另外比對過 worktree 與 HEAD 的差異，確認我讀到的 `load_asr()` / `llm_model_path()` 與 HEAD 完全一致（證據 4.1）。

---

### 1. git 狀態

**結論：通過**（就「4 個 commit 的內容與訊息相符、沒有把不該進版控的東西加進去」而言）。但工作區現在不乾淨，原因是 agent 正在進行中的新工作，不是這 4 個 commit 的問題。

**證據：**

1.1 查核起點的 git 狀態：

```
$ git log --oneline -6 && git status --short && git branch -vv
6ea26b9 feat(engine): Qwen3.5-2B by default, int8 ASR, thinking-off prefill
45a7f47 build: refuse to package an ad-hoc signed app
985e939 feat(app): history, translation, system-audio capture, permission UX
1e846ed fix(summary): enforce decision/action cleanup in code
a2f2059 Improve cleanup quality and rebuild the HUD as a 文青 capsule
01a5d39 feat(app): dictation polishes via LLM with raw fallback; WAV self-test path (test-only env var)
---STATUS---
---BRANCH---
* main 6ea26b9 feat(engine): Qwen3.5-2B by default, int8 ASR, thinking-off prefill
```

1.2 查核結束時（01:03:49）工作區已不乾淨：

```
$ git status --short
 M rust/core_engine/src/lib.rs
 M rust/core_engine/src/state.rs
 M mac/macos_app/Resources/Info.plist
 M mac/macos_app/Sources/COfflineVoiceCore/include/offline_voice_core.h
 M mac/macos_app/Sources/OfflineVoiceAssistant/CoreBridge.swift
 M mac/macos_app/Sources/OfflineVoiceAssistant/main.swift
?? rust/core_engine/src/segmentation.rs
?? mac/macos_app/Sources/OfflineVoiceAssistant/CalendarNaming.swift
?? mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift
?? mac/macos_app/Sources/OfflineVoiceAssistant/ModelDownloader.swift
?? mac/macos_app/Sources/OfflineVoiceAssistant/Naming.swift
?? mac/macos_app/Sources/OfflineVoiceAssistant/Theme.swift
?? mac/macos_app/Sources/OfflineVoiceAssistant/TranscriptExport.swift
?? mac/macos_app/Sources/OfflineVoiceAssistant/TranscriptModel.swift
?? scripts/ab_models.sh
?? scripts/ab_report.sh
```

1.3 四個 commit 的檔案清單（`git show --stat`）——全部是原始碼／設定，**沒有**模型檔、`dist/`、`.dmg`、暫存檔：

```
$ git show --stat --format="" 1e846ed
 rust/core_engine/examples/meeting_summary.rs  |  21 +
 rust/core_engine/include/offline_voice_core.h |   8 +
 rust/core_engine/src/bin/ovc-llm-worker.rs   |   1 +
 rust/core_engine/src/lib.rs                   |  17 +-
 rust/core_engine/src/llm.rs                   | 236 +++++++++++++-
 rust/core_engine/src/state.rs                 | 663 ++++++++++++++++++++++++++++++-
$ git show --stat --format="" 985e939
 mac/macos_app/Resources/Info.plist                     |   2 +
 .../COfflineVoiceCore/include/offline_voice_core.h |   4 +
 .../Sources/OfflineVoiceAssistant/CoreBridge.swift |  10 +
 .../Sources/OfflineVoiceAssistant/HUDWindow.swift  |  54 ++++-
 .../Sources/OfflineVoiceAssistant/History.swift    |  83 +++++++
 .../Sources/OfflineVoiceAssistant/MainWindow.swift | 217 ++++++++++++-
 .../OfflineVoiceAssistant/SystemAudioTap.swift     | 247 +++++++++++++++++++
 mac/macos_app/Sources/OfflineVoiceAssistant/main.swift | 266 +++++++++++++++++++--
$ git show --stat --format="" 45a7f47
 scripts/package_dmg.sh | 33 +++++++++++++++++++++++++++++++++
$ git show --stat --format="" 6ea26b9
 rust/core_engine/src/llm.rs   | 73 +++++++++++++++++++++++++++++++++++++++
 rust/core_engine/src/state.rs | 34 ++++++++++++++++---
 models/manifest.json     | 88 +++++++++++++++++++++++++++++++++++-----
```

新增行數最多的也只有 663 行（`state.rs`），沒有任何大 blob：

```
$ for c in 1e846ed 985e939 45a7f47 6ea26b9; do git show --numstat --format="" $c | awk -v c=$c '$1!="-" && $1+0>500 {print c, $3, $1" lines"}'; done
1e846ed rust/core_engine/src/state.rs 659 lines
```

1.4 `1e846ed` 訊息裡的「23 unit tests」是可成立的（指該 commit 之後整個 crate 的測試總數，不指「新增 23 個」）：

```
$ for f in asr chunking llm state vad; do printf "%-10s %s\n" "$f.rs" "$(git show 1e846ed:rust/core_engine/src/$f.rs | grep -c '#\[test\]')"; done
asr.rs     1
chunking.rs 4
llm.rs     0
state.rs   16
vad.rs     2
TOTAL: 23
```

1.5 未追蹤／被忽略的東西沒有混進版控：

```
$ git status --porcelain --ignored | head
!! .DS_Store
!! .freebuff/
!! rust/core_engine/target/
!! rust/core_engine/vendor/
!! dist/
!! mac/macos_app/.DS_Store
!! mac/macos_app/.build/
!! mac/macos_app/Sources/.DS_Store
!! models/asr/
!! models/llm/
```

**風險：**
- 01:00 之後新增的 9 個未追蹤檔（`ModelCatalog.swift`、`ModelDownloader.swift`、`TranscriptExport.swift`、`segmentation.rs`、`scripts/ab_models.sh`…）目前完全不在版控裡，其中包含**引擎對外 ABI 的改動**（`offline_voice_core.h` 被改）、`Info.plist` 被改。若中途 commit，會出現「ABI 頭檔改了但新 Swift 檔沒進版控」的半套狀態。
- `dist/OfflineVoiceAssistant.dmg`（10月20 00:39）早於 `45a7f47`（00:39:40）加入的簽章守門，所以現存 DMG 是**繞過守門**產生的舊產物（詳見第 6 項）。

---

### 2. 模型檔

**結論：通過。** 檔案存在、大小與 sha256 與宣稱值**完全一致**，`models/llm/` 確實被版控排除。

**證據：**

2.1 存在性與大小：

```
$ ls -la models/llm/
-rw-------  1 joyyang  staff  1117320736 10月 18 09:56 qwen2.5-1.5b-instruct-q4_k_m.gguf
-rw-r--r--  1 joyyang  staff  1280835840 10月 20 00:43 Qwen3.5-2B-Q4_K_M.gguf
$ stat -f "%N size=%z" models/llm/Qwen3.5-2B-Q4_K_M.gguf
models/llm/Qwen3.5-2B-Q4_K_M.gguf size=1280835840
```

2.2 sha256（自行計算，非引用 manifest）：

```
$ shasum -a 256 models/llm/Qwen3.5-2B-Q4_K_M.gguf
aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223  models/llm/Qwen3.5-2B-Q4_K_M.gguf
```

與宣稱的 `aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223` 一致。

2.3 排除規則：

```
$ cat .gitignore
target/
models/*.onnx
models/*.gguf
models/*.bin
models/downloads/
models/sherpa/
build/
dist/
*.dmg
.build/
.DS_Store
rust/core_engine/vendor/
models/asr/
models/llm/
models/rag/

$ git check-ignore -v models/llm/ models/llm/Qwen3.5-2B-Q4_K_M.gguf models/asr/model.int8.onnx dist/ dist/*
.gitignore:14:models/llm/	models/llm/
.gitignore:14:models/llm/	models/llm/Qwen3.5-2B-Q4_K_M.gguf
.gitignore:13:models/asr/	models/asr/model.int8.onnx
.gitignore:8:dist/	dist/
.gitignore:8:dist/	dist/OfflineVoiceAssistant.app
.gitignore:8:dist/	dist/OfflineVoiceAssistant.dmg
```

**風險：**
- `models/llm/qwen2.5-1.5b-instruct-q4_k_m.gguf` 的權限是 `-rw-------`（600），而新的 `Qwen3.5-2B-Q4_K_M.gguf` 是 644。兩者不一致；對 app 沒有影響（同一個 user），但若日後改成用不同帳號跑打包流程會踩到。
- manifest 把 `llm-qwen2.5-1.5b-instruct-q4-k-m` 標成 `download: false`，但 `LLMSelection.legacyFileName` 又把它當成「最後手段」的名字。新安裝的使用者若 Qwen3.5-2B 還沒下載完，會被導到一個**永遠不會被下載**的檔名上（見第 4 項的靜默 fallback 風險）。

---

### 3. manifest

**結論：通過。** JSON 合法；`download:true` 共 3 筆、總量 **1,520,385,575 bytes（1449.95 MiB / 1520.39 MB）**；兩個關鍵 sha256 與磁碟實檔完全一致；`ModelInstaller.items()` **不會**因為 `download:false` 或 `sha256:"PENDING"` 而拋錯。

**證據：**

3.1 合法 JSON + 下載項統計（直接用 manifest 計算）：

```
$ python3 -c "import json; d=json.load(open('models/manifest.json')); print('VALID JSON, top keys:', list(d.keys()))"
VALID JSON, top keys: ['schema_version', 'budget_note', 'language_note', 'selection_note', 'models']

download:true entries:
   asr-sensevoice-small-int8 239233841 bytes
   asr-sensevoice-tokens 315894 bytes
   llm-qwen3.5-2b-q4-k-m 1280835840 bytes
TOTAL bytes = 1520385575
= 1449.95 MiB (1048576) = 1520.39 MB (1e6)

download:false entries: ['asr-sensevoice-small-fp32', 'llm-qwen3.5-2b-q5-k-m',
  'llm-qwen3.5-0.8b-q4-k-m', 'llm-qwen3.5-4b-q4-k-m',
  'llm-qwen2.5-1.5b-instruct-q4-k-m', 'rag-embeddinggemma-300m']
rows with sha256 PENDING: [('rag-embeddinggemma-300m', False)]
rows missing download key: []
```

3.2 manifest 的 sha256 vs 磁碟實檔（我另外把三個檔案都算過）：

```
$ shasum -a 256 models/asr/model.int8.onnx models/asr/tokens.txt models/asr/model.onnx
c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51  models/asr/model.int8.onnx
f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc  models/asr/tokens.txt
977016bd9c79f9eb343430b5cc305e07ab64d5212dff41b0dcfa1694bee9a8cb  models/asr/model.onnx

manifest sha256 Qwen3.5-2B : aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223
manifest sha256 int8 ASR  : c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51
```

三筆 `download:true` 的 hash **全部**與磁碟實檔一致。`verify_models.sh` 亦全綠：

```
$ bash scripts/verify_models.sh
OK       asr-sensevoice-small-int8
OK       asr-sensevoice-tokens
OK       llm-qwen3.5-2b-q4-k-m
exit=0
```

3.3 `items()` 為什麼不會拋錯（`mac/macos_app/Sources/OfflineVoiceAssistant/ModelInstaller.swift:84-95`）：

```swift
return try models.compactMap { m in
    guard (m["download"] as? Bool) ?? true else { return nil }   // ← download:false 在這裡就被丟棄
    let id = m["id"] as? String ?? "?"
    guard let src = m["source_url"] as? String, let u = URL(string: src),
          let file = m["file"] as? String,
          let bytes = (m["bytes"] as? NSNumber)?.int64Value,
          let sha = m["sha256"] as? String else {
        throw InstallError.manifestInvalid("entry \(id) incomplete")
    }
    guard sha != "PENDING" else { throw InstallError.manifestInvalid("entry \(id) has no sha256") }
    return Item(id: id, url: u, file: file, bytes: bytes, sha256: sha)
}
```

`download:false` 的列在第一道 `guard` 就 `return nil` 被 `compactMap` 丟掉，**永遠走不到** `sha256 != "PENDING"` 那道檢查；而唯一 `PENDING` 的列（`rag-embeddinggemma-300m`）正好是 `download:false`。所以現在不會拋錯——這是「靠資料巧合」而不是「靠結構保證」：只要有人把 RAG 那列翻成 `download:true`，`items()` 就會以 `manifestInvalid("entry rag-embeddinggemma-300m has no sha256")` 整個安裝流程失敗。`download_models.sh:47-56` 與 `verify_models.sh:21-23` 對 `PENDING` 都有處理，行為一致。

**風險：**
- `items()` 對缺 `download` 欄位的列採 **`?? true`（fail-open）**：`guard (m["download"] as? Bool) ?? true else { return nil }`。`download_models.sh:21` 與 `verify_models.sh:32` 也用同樣的 `e.get("download", True)`。目前每一列都有 `download` 鍵，所以是潛在問題，但語意方向錯了——缺欄位應該預設 `false`（不自動下載）。
- manifest 的 `selection_note` 宣稱：「The rest are offered by the model manager, which writes the chosen LLM filename to UserDefaults and exports it as OVC_LLM_MODEL for the engine.」**已提交的 tree 裡沒有任何 model manager**，也沒有任何 Swift 端設定 `OVC_LLM_MODEL` 的程式碼（見第 7 項 d 的證據）。這是已提交檔案裡的一個不實敘述。
- manifest 的 `budget_note` 寫「App bundle target <= 700 MB」，但 `download:true` 總量已是 1.45 GiB。兩者不衝突（模型不打包），但「700 MB」這個數字現在只跟 DMG 有關，且 README 仍寫「~1.96 GB」下載量（已過時）。
- manifest 把 `llm-qwen2.5-1.5b-instruct-q4-k-m` 標成 `download:false`，但它是引擎的 fallback。既有安裝有它，新安裝沒有——fallback 的實際可用性在 manifest 層面沒有保證。

---

### 4. `rust/core_engine/src/state.rs`

**結論：部分通過。** `load_asr()` 的 int8 優先與 `llm_model_path()` 的路徑穿越防護都正確；**但**穿越防護有破口（`.`），fallback 是靜默的，而且 `file_len` 的錯誤訊息有細節問題。

**證據：**

4.1 確認我讀到的是 HEAD 的版本（worktree 已被 agent 改寫）：

```
$ git show HEAD:rust/core_engine/src/state.rs | grep -n -A 22 "^pub fn load_asr"
62:pub fn load_asr() -> Result<()> {
63-    let mut s = lock();
64-    if s.asr.is_some() {
65-        return Ok(());
66-    }
...
75-    let int8 = dir.join("asr/model.int8.onnx");
76-    let model = if int8.exists() { int8 } else { dir.join("asr/model.onnx") };
77-    let tokens = dir.join("asr/tokens.txt");
78-    let bytes = file_len(&model)? + file_len(&tokens)?;
```

`git diff HEAD -- rust/core_engine/src/state.rs` 顯示 worktree 已被改成全新的 segmentation／speaker 分流架構（新增 `rust/core_engine/src/segmentation.rs`、`asr_submit_tagged`），但 `load_asr()` 與 `llm_model_path()` 在 HEAD 與 worktree 兩邊相同（`git show HEAD:...` 的輸出與我先前讀到的一致）。

4.2 `load_asr()`：int8 優先、fp32 回退 ✓，且**不存在**時的錯誤訊息可讀：

```rust
let int8 = dir.join("asr/model.int8.onnx");
let model = if int8.exists() { int8 } else { dir.join("asr/model.onnx") };
let bytes = file_len(&model)? + file_len(&tokens)?;
```

`file_len`（`state.rs:209`）：

```rust
fn file_len(p: &Path) -> Result<u64> {
    std::fs::metadata(p)
        .map(|m| m.len())
        .map_err(|e| EngineError::new(ErrorCode::ModelLoad, format!("{}: {e}", p.display())))
}
```

訊息形如 `<path>: No such file or directory (os error 2)`，錯誤碼 `ErrorCode::ModelLoad`（`error.rs:10`）。可讀，但 `file_len` 這個名字**完全沒有透露它其實被當成「存在性檢查 + 長度讀取」兩用**：`state.rs:273` 與 `state.rs:278` 只呼叫它來讓「檔案不存在」變成錯誤，長度值直接丟棄。

4.3 `llm_model_path()`（`state.rs:261-283`，HEAD 版本）：

```rust
let chosen = std::env::var("OVC_LLM_MODEL")
    .ok()
    .map(|v| v.trim().to_string())
    .filter(|v| !v.is_empty() && !v.contains('/') && !v.contains(".."))
    .unwrap_or_else(|| DEFAULT_LLM_FILE.to_string());
let model = dir.join("llm").join(&chosen);
if model.exists() {
    file_len(&model)?;
    return Ok(model);
}
let legacy = dir.join("llm").join(LEGACY_LLM_FILE);
if legacy.exists() {
    file_len(&legacy)?;
    return Ok(legacy);
}
file_len(&model)?;
Ok(model)
```

穿越防護邏輯（用 Python 逐字模擬同一條件）：

```
'Qwen3.5-2B-Q4_K_M.gguf' -> accepted
'qwen2.5-1.5b-instruct-q4_k_m.gguf' -> accepted
'../../etc/passwd' -> REJECTED
'..' -> REJECTED
'.' -> accepted          ← 破口
'...' -> REJECTED
'/etc/passwd' -> REJECTED
'a/../b' -> REJECTED
'' -> REJECTED
'   ' -> REJECTED
'..Qwen.gguf' -> REJECTED
```

- `/` 與 `..` 的**路徑穿越確實被擋掉**，`..` 的任何位置都擋（連合法的 `..Qwen.gguf` 也被誤殺，過度嚴格但安全）。
- **破口**：`"."` 不含 `/` 也不含 `..`，所以通過。`dir.join("llm").join(".")` = `<models>/llm/.`，而 `Path::exists()` 對**目錄**回傳 true → `file_len` 對目錄 `metadata().len()` 成功 → 引擎把一個**目錄路徑**交給 worker，llama.cpp 載入失敗，使用者看到的是一個莫名其妙的「載入模型失敗」。不是安全漏洞（仍在 models/llm 之內），但屬於「防護寫得不嚴謹」。

4.4 fallback 到舊模型 ✓ 存在，但**完全靜默**：當 `OVC_LLM_MODEL` 指定的檔不存在、而 legacy 存在時，引擎直接改用 legacy，**不對上層回報任何差異**。工作區中（尚未提交）的 `ModelCatalog.swift:246-262` 讓 `LLMSelection.currentFileName` 保留「使用者選了但還沒下載完成」的名字，兩邊疊加後的行為是：使用者明確選了 4B、但檔案還沒下載完 → 引擎**安靜地**用 1.5B 舊模型產出結果。

**風險：**
- `OVC_LLM_MODEL="."` 破口（如上）。
- 靜默 fallback 沒有任何 log／錯誤／UI 提示。使用者以為在跑 4B，實際跑的是 1.5B，輸出品質差異不會被告知。建議：fallback 時回傳一個可觀測的旗標（至少寫進 `ova.log`）。
- `file_len` 兼具「探測存在」與「取長度」兩種語意，讀者容易誤用；建議拆成 `require_file()` / `file_len()`。
- 找不到時的錯誤訊息只指出**被選的那個**檔案（例如 `Qwen3.5-4B-Q4_K_M.gguf: No such file or directory`），沒有說明「legacy fallback 也一併找過、也沒有」。對使用者判斷是「沒下載」還是「路徑壞掉」幫助有限。
- `file_len` 回傳 `u64`，`asr_model_bytes` 記的是**檔案大小**不是**實際 RSS**，`usage()` 的 `model_bytes` 會被當成記憶體用量來看。README 說 int8 省 698 MB，是檔案大小差（937,617,178 − 239,233,841 = 698,383,337 bytes ≈ 698 MB / 666 MiB，算術正確），但**不是**實測 RSS 差異。

---

### 5. `rust/core_engine/src/llm.rs`（thinking 關閉機制）

**結論：不通過（核心宣稱失效）。** 三個子問題：`insert_think_block` 確實只插在**最後一個** assistant turn 之後 ✓；`template_uses_thinking` 確實讀 **GGUF metadata**（不是檔名）✓；`generate_in` 確實有呼叫 `with_thinking_disabled` ✓。**但偵測條件在真實的 Qwen3.5-2B 模板上恆為 false，於是這個機制對新的預設模型完全不會啟動**——也就是 commit 訊息所說的「prefilled with a closed empty think block」實際上沒有發生。

**證據：**

5.1 原始碼（`rust/core_engine/src/llm.rs`）：

```rust
const ASSISTANT_TURN: &str = "<|im_start|>assistant\n";
const EMPTY_THINK_BLOCK: &str = " thinking\n\n</thinking>\n\n";

fn insert_think_block(prompt: &str) -> std::borrow::Cow<'_, str> {
    match prompt.rfind(ASSISTANT_TURN) {          // ← rfind：只取最後一個
        Some(i) => {
            let at = i + ASSISTANT_TURN.len();
            ...
        }
        None => std::borrow::Cow::Borrowed(prompt),
    }
}

fn template_uses_thinking(model: &LlamaModel) -> bool {
    model
        .meta_val_str("tokenizer.chat_template")  // ← 真的讀 GGUF metadata
        .map(|t| t.contains(" thinking"))          // ← 但這個字串不存在
        .unwrap_or(false)
}

fn with_thinking_disabled<'a>(model: &LlamaModel, prompt: &'a str) -> std::borrow::Cow<'a, str> {
    if template_uses_thinking(model) { insert_think_block(prompt) } else { Cow::Borrowed(prompt) }
}

fn generate_in(model: &LlamaModel, prompt: &str, max_new_tokens: usize) -> Result<String> {
    ...
    let vocab = model.vocab();
    let prompt = with_thinking_disabled(model, prompt);   // ← 確實有接上
    let tokens = vocab.tokenize(prompt.as_bytes(), false, true);
```

`meta_val_str` 確實存在於所用版本（`llama-cpp-2 0.1.159`）：

```
$ grep -n "pub fn meta_val_str" ~/.cargo/registry/src/index.crates.io-*/llama-cpp-2-0.1.159/src/model.rs
232:    pub fn meta_val_str(&self, key: &str) -> Result<String, MetaValError> {
```

5.2 **關鍵證據：實際 GGUF 的 chat template 內容。** 我直接從 `models/llm/Qwen3.5-2B-Q4_K_M.gguf` 解析 metadata（GGUF v3：key 後面是 u32 value type，再是 u64 長度）：

```
$ python3 -c "
p='models/llm/Qwen3.5-2B-Q4_K_M.gguf'; off=10934907; key=b'tokenizer.chat_template'
f=open(p,'rb'); f.seek(off+len(key))
vt=int.from_bytes(f.read(4),'little'); n=int.from_bytes(f.read(8),'little')
tpl=f.read(n).decode('utf-8','replace')
print('value_type',vt,'len',n)
print('has \" thinking\" :', ' thinking' in tpl)
print('has think        :', 'think' in tpl)
print('has <think>      :', '<think>' in tpl)
"
value_type 8 len 7816
has " thinking" : False
has think        : True
has <think>      : True
```

模板裡的實際片段（節錄）：

```
{{- '<|im_start|>assistant\n' }}
{%- if enable_thinking is defined and enable_thinking is true %}
    {{- '<think>\n' }}
{%- else %}
    {{- '<think>\n\n</think>\n\n' }}
{%- endif %}
```

也就是說：
- 模板裡有 `<think>` / `</think>` / `enable_thinking`，但**沒有任何一個「空格 + thinking」的子字串**（`enable_thinking` 前面是底線 `_` 不是空格）。
- 因此 `t.contains(" thinking")` 恆為 **false** → `template_uses_thinking()` 回傳 false → `with_thinking_disabled()` 原封不動回傳 prompt → **Qwen3.5-2B（新的預設模型）從來不會被預填 think block**。commit `6ea26b9` 訊息裡「prompts are prefilled with a closed empty block」在實際執行路徑上是**不成立的**。

5.3 對照組：Qwen2.5 的模板確實沒有 think（所以「Qwen2.5 不受影響」這部分結論成立）：

```
$ python3 -c "... qwen2.5-1.5b-instruct-q4_k_m.gguf ..."
Qwen2.5 template len 2509
has " thinking" : False
has think        : False
has <think>     : False
```

5.4 **即使修好偵測，注入的內容格式也不對。** 模板在「關閉思考」時吐的是 `<think>\n\n</think>\n\n`；程式注入的是 `" thinking\n\n</thinking>\n\n"`——開頭多了空格、結尾是 `</thinking>`（斜線）而不是 `</think>`。這兩個是否為模型的 special token 會影響 tokenize 結果（`parse_special = true`）。程式用 `t.contains(" thinking")` 這個寫法，很可能正是從某個「空格 + thinking」風格的模板（而不是 Qwen3.5 家族）抄來的。

5.5 三個新測試**確實在測真正的函式**（不是複製字串處理），但**不可能抓到上面這個 bug**：

```rust
#[test]
fn think_block_lands_before_the_answer() {
    let prompt = format!("{ASSISTANT_TURN}你好");
    let out = insert_think_block(&prompt);
    assert_eq!(out, format!("{ASSISTANT_TURN}{EMPTY_THINK_BLOCK}你好"));
    assert!(out.ends_with("你好"), "the transcript must stay after the block");
}

#[test]
fn think_block_only_touches_the_last_turn() {
    let prompt = format!("{ASSISTANT_TURN}one{ASSISTANT_TURN}two");
    let out = insert_think_block(&prompt);
    assert_eq!(out, format!("{ASSISTANT_TURN}one{ASSISTANT_TURN}{EMPTY_THINK_BLOCK}two"));
}

#[test]
fn think_block_is_a_no_op_without_an_assistant_turn() {
    let prompt = "not a chat prompt";
    assert_eq!(insert_think_block(prompt), prompt);
}
```

- 優點：呼叫的是 `insert_think_block` 本體，沒有自己重寫一份字串邏輯。
- 弱點一：斷言兩邊都用同一組常數 `ASSISTANT_TURN` / `EMPTY_THINK_BLOCK`，所以**常數內容寫錯也測不出來**（例如把 `EMPTY_THINK_BLOCK` 改成 `" garbage"` 測試照樣過）。
- 弱點二：**完全沒有覆蓋 `template_uses_thinking()` 與 `with_thinking_disabled()`**——而真正的 bug 就在前者。
- 弱點三：沒有任何「真的載入 GGUF、真的生成一次」的端對端測試，所以「模型會不會把 thinking 串進答案裡」從未被自動化驗證過。

**風險：**
- 這是本輪最嚴重的問題：**預設模型 Qwen3.5-2B 的 thinking 抑制機制是無效的**，實際行為會退化成 commit 訊息所警告的「模型把自己的推理串進答案」。而三個單元測試給了「已覆蓋」的假安全感。
- 建議修法：偵測條件改為 `t.contains("<think>")` 或 `t.contains("enable_thinking")`；注入字串改為與模板一致的 `<think>\n\n</think>\n\n`；並補一個「用真實 GGUF 讀 metadata」的整合測試（或至少把模板字串抽成可測的常數，測 `contains` 判斷）。
- `with_thinking_disabled` 這個名字誤導：它並沒有「disable」任何開關，只是預填字串。

---

### 6. `scripts/package_dmg.sh`

**結論：通過（ad-hoc 判斷不會誤判合法簽章），但有兩個策略／位置上的問題。**

**證據：**

6.1 語法：

```
$ for f in scripts/*.sh; do printf "%-40s " "$f"; bash -n "$f" && echo "SYNTAX OK"; done
scripts/ab_models.sh                     SYNTAX OK
scripts/build_macos.sh                   SYNTAX OK
scripts/download_models.sh               SYNTAX OK
scripts/package_dmg.sh                   SYNTAX OK
scripts/verify_models.sh                 SYNTAX OK
```

6.2 **不會誤判合法簽章**：本機實際簽過的 app，其 designated requirement 裡沒有 `cdhash`：

```
$ codesign -d -r- dist/OfflineVoiceAssistant.app
Executable=/Users/joyyang/Documents/open typeless/dist/OfflineVoiceAssistant.app/Contents/MacOS/OfflineVoiceAssistant
designated => identifier "com.example.offlinevoiceassistant" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: joeyyang0429@icloud.com (4YUA66JY2M)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
```

ad-hoc 簽章的 DR 才會是 `designated => cdhash H"…"`。所以 `grep -q 'cdhash'` 這道判斷對 Apple Development / Developer ID 都不會誤判 ✓。

6.3 ad-hoc 的第二道判斷與 `TeamIdentifier` 檢查也對得上現況：

```
$ codesign -dv --verbose=2 dist/OfflineVoiceAssistant.app
Identifier=com.example.offlinevoiceassistant
Authority=Apple Development: joeyyang0429@icloud.com (4YUA66JY2M)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=7S48J3H2N2
```

6.4 TCC 警告在這台機器上**確實會生效**，而且判斷正確。系統 TCC.db 實際上是 world-readable：

```
$ ls -la /Library/Application\ Support/com.apple.TCC/TCC.db
-rw-r--r--  1 root  wheel  73728 10月 19 23:24 /Library/Application Support/com.apple.TCC/TCC.db
$ [[ -r /Library/Application\ Support/com.apple.TCC/TCC.db ]] && echo "SYSTEM READABLE"
SYSTEM READABLE

$ sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select service, client, length(csreq), hex(csreq) from access where client='com.example.offlinevoiceassistant';"
kTCCServiceAccessibility|com.example.offlinevoiceassistant|40|FADE0C0000000028000000010000000800000014538254829829F76A2986C3A1962497B974EEA571
```

這筆 csreq 只有 40 bytes（hex 80 個字元）= 典型的 **cdhash-only 需求**（`FADE0C` magic + `kSecCsReqBlobFlagCdhash`），小於腳本的 200 門檻 → 警告會正確觸發 ✓。使用者的 user-level TCC.db 裡則是另外兩筆（`kTCCServiceMicrophone` / `kTCCServiceSystemPolicyDocumentsFolder`，各 188 bytes = 376 hex，> 200 不會誤報）。

6.5 現存的 DMG 是**繞過守門**做出來的舊產物：

```
$ ls -laT dist/
-rw-r--r--@  1 joyyang  staff  13641319 10月 20 00:39 dist/OfflineVoiceAssistant.dmg
drwxr-xr-x@  5 joyyang  staff        160 10月 20 00:39 dist
drwxr-xr-x@  3 joyyang  staff         96 10月 19 16:11 dist/OfflineVoiceAssistant.app
```

`dist/OfflineVoiceAssistant.app` 裡的引擎與 worker 都是**舊的**（hash 對不上目前的 release 產物）：

```
$ shasum -a 256 dist/OfflineVoiceAssistant.app/Contents/Frameworks/liboffline_voice_core.dylib \
    rust/core_engine/target/release/deps/liboffline_voice_core.dylib \
    rust/core_engine/target/release/liboffline_voice_core.dylib
de88de319abc1c669a9c2bd5d5fd893d9c58283615606d2cc7eee97f6ef84191  dist/.../liboffline_voice_core.dylib
0ada4d0e9984045e062e0bb691266a4dd9443d677f53df35ce86d5cc61e934b3  rust/core_engine/target/release/deps/liboffline_voice_core.dylib
5fb624868106a1342a98772414d72cab82e1b3e15f706351a00fc36cb055164e  rust/core_engine/target/release/liboffline_voice_core.dylib

$ shasum -a 256 dist/.../ovc-llm-worker rust/core_engine/target/release/ovc-llm-worker
b5d2b1243398cdc3c2acf1aa3db5ed4ae6e09d721e7722b407d3f2b97088e58d  dist/.../ovc-llm-worker
3fca076eb104dbcdcc07833adffd41bbe2027e0e73e73de9ff3bdfc726c85a57  rust/core_engine/target/release/ovc-llm-worker
```

也就是說：**目前 `dist/` 裡的 app 與 DMG 不含 `6ea26b9` 的 int8 ASR / Qwen3.5 / think-block 任何改動**（app bundle 是 10月19 16:11 的）。`scripts/build_macos.sh:31-32` 優先從 `target/release/deps/` 拷貝（該份是 10月20 00:44 的新產物），所以**重跑一次 build 即可修正**；`target/release/` 頂層那份 `.a/.rlib/.dylib` 反而是舊的（10月19 16:04），只有 fallback 會用到。

**風險：**
- **過度嚴格，擋住正常的發行路徑。** 腳本硬性要求 `Authority=Apple Development` 且 `TeamIdentifier=7S48J3H2N2`。用 **Developer ID Application** 憑證做正式發行（這才是對外分發的正常身分）的 build 會被直接 `exit 1`，即使它的簽章完全穩定、DR 也不含 cdhash。commit 訊息寫的是「refuse to package an ad-hoc signed app」，但實作上拒絕的範圍大得多。建議：只把 cdhash 當硬性阻擋，Apple Development 降級為警告。
- **TCC 查詢位置可移植性差。** 腳本查的是**系統** TCC.db，而使用者層級 App 的 Accessibility 授權實際記在**使用者** TCC.db（`~/Library/Application Support/com.apple.TCC/TCC.db`）。這台機器上剛好系統 db 有一筆殘留的 cdhash 記錄所以能觸發，但在一般機器上 `-r` 測試會失敗 → 整段跳過，警告等於沒有。腳本註解「The system TCC database is normally root-only, in which case this check is skipped」與本機事實（`-rw-r--r--` world-readable）不符。
- 門檻 `${#REQ} -lt 200` 是經驗值，沒有註解說明 200 對應到什麼；本機實測 cdhash-only = 80 hex、完整 DR = 376 hex，分隔得很開，但門檻本身是硬的、沒有對照說明。
- `dist/` 內的 DMG 是在守門加入**之前**產生的舊物，卻留在 `dist/` 裡容易被當成可交付物。建議刪除或重打包。

---

### 7. 找碩

#### 7a. `main.swift` 的 `sessionStarting` 競態

**結論：通過（這個競態確實修好了）。** 但附帶兩個副作用。

**證據：**

7a.1 claim 是同步取得的，且在同一條執行緒上：

```swift
/// True between a start being requested and the ASR session actually being up.
/// ... This claim is taken synchronously.
private var sessionStarting = false
...
func toggleDictation() {
    guard !meeting, !sessionStarting else {
        if meeting { hud.notice("會議錄音中，請先結束會議") }
        return
    }
    if !ready { pendingAction = .dictation; ensureModelsLoaded(); return }
    if dictating { stopDictation() } else { startDictation() }
}

private func startDictation() {
    guard AudioCapture.microphoneAuthorized() else { ...; return }
    guard !sessionStarting else { return }
    sessionStarting = true          // ← 在 async 之前、同步設定
    coreQueue.async {
        do { try Core.startASR() } catch { ... return }
        DispatchQueue.main.async {
            self.sessionStarting = false
            self.dictating = true
            ...
        }
    }
}
```

7a.2 熱鍵回呼在主執行緒（Carbon 的 application event target 就是主執行緒的事件迴圈），所以 `sessionStarting` 沒有跨執行緒資料競爭：

```swift
let status = InstallEventHandler(
    GetApplicationEventTarget(),
    { _, _, _ in
        Hotkey.instance?.onPress()      // ← 主執行緒
        return noErr
    },
    1, &eventSpec, nil, &handler
)
```

7a.3 `coreQueue` 是序列佇列，`Core.stopASR()` 與 `Core.startASR()` 的先後順序因此保證：

```swift
private let coreQueue = DispatchQueue(label: "ovc.core")   // 預設 serial
```

結論：快速連按熱鍵**不會**開兩個 session——第二次 `toggleDictation()` 會在 `!sessionStarting` 這個 guard 被擋下。

**風險：**
- **啟動視窗內第二次按熱鍵是「完全無聲地」被吞掉的。** `toggleDictation()` 的 guard 分支只在 `meeting` 為 true 時 `hud.notice(...)`；`sessionStarting` 為 true 時**沒有任何提示**。使用者的體感是「我按了兩次，錄音卻沒停」。
- **HUD 膠囊的停止按鈕在啟動視窗內是死的。** `stopFromCapsule()` 只檢查 `meeting` / `dictating`，兩者此時都還沒被設為 true → 按了沒反應，而且啟動完成後錄音還會繼續。使用者會以為自己按了停止。
- **`stopDictation()` 沒有佔用 `sessionStarting`。** 所以在 `Core.stopASR()` 還在 coreQueue 上跑（解碼剩餘緩衝，可能要數秒）的期間，使用者再按一次熱鍵就會排入新的 `Core.startASR()`。序列佇列保證 `stop` 在 `start` 之前，但**上一段語音的 `deliver(text)` 仍會在錄音已經重新開始之後才被貼上**——使用者會在錄下一句話的當下，被貼入上一句的內容。建議 `stopDictation()` 也設一個 `sessionStarting`（或另設 `stopping`）旗標。
- 麥克風與系統音訊是**以不同 chunk 交錯送進同一個 ASR session**（`Core.submit(samples)`），而兩者來自不同執行緒（`ioQueue` / 麥克風回呼），所以**時間順序不保證**、也沒有說話人標記。commit 訊息寫「concatenates it with the microphone into one ASR stream」字面正確，但後果（順序亂、無 speaker 區分、揚聲器時同一句話出現兩次）沒有寫出來。

#### 7b. `SystemAudioTap.swift` 的 process tap 生命週期

**結論：部分通過。** `muteBehavior` 確實是 `.unmuted` ✓；一般錯誤路徑都有清理 ✓；**但有一條路徑會洩漏 process tap**。

**證據：**

7b.1 `muteBehavior`：

```swift
let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
description.name = "Offline Voice Assistant"
description.uuid = UUID()
description.isPrivate = true
description.muteBehavior = .unmuted      // ← 系統音訊不會被靜音
```

7b.2 `stop()` 會完整釋放三個資源：

```swift
func stop() {
    if aggregateID != AudioObjectID(kAudioObjectUnknown) {
        if let proc = ioProcID {
            _ = AudioDeviceStop(aggregateID, proc)
            _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }
    ioProcID = nil
    if tapID != AudioObjectID(kAudioObjectUnknown) {
        if #available(macOS 14.2, *) { _ = AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
    converter = nil
    inputFormat = nil
}
```

`main.swift` 的三個退出點也都呼叫了 `stop()`：`stopMeeting()`（`systemTap?.stop(); systemTap = nil`）、`applyMeetingSystemAudioChange(false)`、`shutdown()`（`willTerminate` 觀察者）。

7b.3 **洩漏路徑**：`start()` 在**已建立 process tap 之後**才去取得預設輸出裝置，而那一步會拋錯，且沒有任何清理：

```swift
let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
guard tapStatus == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
    throw TapError.create(tapStatus)
}
tapID = tap

// A tap cannot be read directly: it has to be published inside an aggregate device...
let outputUID = try Self.defaultOutputUID()     // ← 拋錯時 tap 已經建立，卻沒有被銷毀
```

`defaultOutputUID()` 在沒有預設輸出裝置時會 `throw TapError.noOutputDevice(status)`。此時 `tapID` 已非 unknown，但錯誤直接往外傳，`stop()` 沒有被呼叫，而 `SystemAudioTap` **沒有 `deinit`**（整個 class 沒有 deinit），所以 `AudioHardwareDestroyProcessTap` 永遠不會被呼叫。**結果：一個 Core Audio process tap 洩漏，系統的「正在錄製系統音訊」指示燈會一直亮著**，直到行程結束。

**風險：**
- 上述 tap 洩漏（中等嚴重：使用者看到永遠關不掉錄音指示燈，會誤以為被監控；而且在 8 GB 機器上多留一條音訊路徑）。
- **`stop()` 與 IOProc 之間的資料競爭。** IOProc block 在 `ioQueue` 上執行 `self?.consume(inputData)`，而 `consume` 讀 `self.inputFormat` / `self.converter`；`stop()` 在**主執行緒**把它們設為 nil。`AVAudioConverter` 本身不是 thread-safe，`stop()` 也沒有等 IOProc 收尾（`AudioDeviceDestroyIOProcID` 的同步性不保證）。這是潛在的 use-after-free。
- **轉換器的輸入供給方式不完整。** `converter.convert(to:error:)` 的 input block 只提供一次資料，之後回 `.noDataNow`；做取樣率轉換時 converter 可能需要比一個 buffer 更多的輸入，此時 `error` 會被設值，而 `guard error == nil, ... else { return }` 會**整段靜默丟棄**。`error` 變數被取出來卻從未被讀取（只當布林用），沒有 log。
- `converter` 沒有在每個 buffer 之間 `reset()`，連續離散 buffer 的取樣率換算比例可能漂移。
- `consume` 每次都配置新的 `AVAudioPCMBuffer`（`AVAudioPCMBuffer(pcmFormat:frameCapacity:)`）並用 `Array(UnsafeBufferPointer(...))` 複製成 Swift array——在 realtime 音訊執行緒上做 heap 配置，會造成音訊週期的 jitter / underrun。註解說「do the conversion there and hand finished 16 kHz samples to the caller's own queue」，但轉換＋複製仍在 IOProc 執行緒上。
- 麥克風與系統音訊送進同一個 ASR session，**沒有任何來源標記**（見 7a 最後一點）。工作區中正在進行的 `segmentation.rs` / `asr_submit_tagged(samples, sample_rate, speaker)` 看起來正是要補這個洞，但那是**尚未提交**的工作。

#### 7c. `state.rs` 的三個過濾器是否會誤砍真實內容

**結論：會。`strip_owner_clauses` 與 `drop_ownerless_restatements` 各有一類真實的誤砍。** `strip_invented_owners` 則是「刻意偏保守」（丟標籤、留任務），風險較低但有誤判面。

**證據與推演：**

7c.1 `strip_invented_owners`：只在 owner **不被 transcript 支持**時丟掉 owner 前綴、保留任務（`state.rs:402-428`）。它靠 `owner_is_backed()` 判斷，cue 表只有 20 個中文 + 6 個英文：

```rust
const OWNER_CUES_CJK: [&str; 20] = [
    "你", "您", "麻煩", "請", "負責", "協助", "幫忙", "這邊", "你們",
    "今天", "明天", "後天", "這週", "這禮拜", "下週", "下個月", "下月", "月底", "月初", "以前",
];
const OWNER_CUES_EN: [&str; 6] = ["will", "please", "could", "can", "should", "'ll"];
```

例如 transcript「今天開會，陳副理說明進度」中的「陳副理」後面接的是「說明進度」，不在 cue 表內 → 判定為虛構 owner → 標籤被丟掉。**任務本身保留**，所以是「少一個名字」而不是「少一件事」——這是刻意取捨，程式註解也明說（「a rejected real owner is an omission, an accepted fake owner is a fabricated fact」）。可接受，但 cue 表偏短，真實人名被當成主題詞的機率不低。

7c.2 **`strip_owner_clauses` 會刪掉「只是提到人名」的決議。** 它的判準是「決議的任一個 clause 只要 `names_owner()` 為真就整個 clause 刪掉」：

```rust
let kept: Vec<(String, String)> = split_clauses(decisions)
    .into_iter()
    .filter(|(clause, _)| !owners.iter().any(|owner| names_owner(clause, owner)))
    .collect();
```

而 `owners` 來自待辦清單中**被 transcript 支持**的 owner。於是：會議決定「Sarah 明年三月退休」，而待辦有「- Sarah: 交接工作」→ 決議的 clause「Sarah 明年三月退休」命名了 Sarah → **整條決議被刪掉**。函式註解只論證了「命名 owner 的 clause 是分派而不是決議」，但「退休/評價/致謝」這類**提到人但不是分派**的決議不在考量內。這是真實內容被誤砍。

7c.3 **`drop_ownerless_restatements` 會刪掉「包含決議內容但多做事」的待辦行。** `restates()` 有兩個方向：

```rust
fn restates(line: &[String], clause: &[String]) -> bool {
    const RESTATED: f32 = 0.60;
    if line.is_empty() || clause.is_empty() { return false; }
    let shared = line.iter().filter(|gram| clause.contains(*gram)).count();
    if (shared as f32) / (line.len() as f32) >= RESTATED { return true; }
    // A short clause contained in a longer line is only a duplicate if the clause
    // is substantial; a two-character grab would match half the list.
    clause.len() >= 4 && (shared as f32) / (clause.len() as f32) >= RESTATED
}
```

第二個條件 `clause.len() >= 4` 的 `clause.len()` 是**bigram 數**，也就是決議 clause 至少要有 5 個字元。於是：

- 決議 clause：「決定停用舊版」→ bigram = 決定/定停/停用/用舊/舊版（5 個）
- 待辦行：「- 停用舊版後要更新說明文件」→ 其 bigram 集合包含 停用/用舊/舊版
- `shared / clause.len()` = 3/5 = 0.60 ≥ 0.60 → **整行待辦被刪掉**，連「後要更新說明文件」這件新工作也一起消失。

同理第一個條件 `shared / line.len() >= 0.60` 會刪掉「短、且與決議有 60% bigram 重疊」的無主待辦行。

7c.4 比較基準是**字元 bigram**（`gram_set`），不是詞。中英文都按字元比，所以英文長字只要部分字元重合就算重疊——程式註解自己說了「character bigrams are too noisy to aim at a short body: English "update the status page" shares 14 of its 18 bigrams with a long unrelated clause, so a real decision got dropped. Needs a word-level test, not this one.」**這個被否决的作法仍以註解形式留在程式碼裡，而目前實際生效的正是 bigram 版的 `restates()`。**

7c.5 過濾器的順序是合理的（先正規化 → 定 owner → 依 owner 過濾決議 → 依決議過濾待辦），且 `drop_ownerless_restatements` 刻意**不做**「保留至少一行」的 fallback（註解說明理由：整段都錯時就是要能清空）。這一點設計是對的。

**風險（依嚴重度）：**
- `drop_ownerless_restatements` 的第二個條件會連帶刪掉決議以外的額外工作（7c.3）——**建議把「包含」與「重述」分開判定**：只有當待辦行的 bigram 集合**幾乎等於**決議 clause（而非只是包含它）才算重述。
- `strip_owner_clauses` 會刪掉「提到人但不是分派」的決議（7c.2）——建議加一個「該 clause 是否真的指派了工作」的判準（動詞／祈使句／時態），而不是只要出現人名就刪。
- `strip_invented_owners` 的 cue 表過短，會把真實 owner 降級成無主任務（7c.1），再被 7c.3 的規則整行刪掉——兩個弱規則疊加後，真實待辦消失的機率比單看任一個都高。
- bigram 比較對英文特別不準（程式註解已自承），但實際生效的仍是 bigram 版本。

#### 7d. 「宣稱做了但其實沒做」

| 宣稱 | 查核結果 | 證據 |
|---|---|---|
| `6ea26b9`：「prompts are prefilled with a closed empty think block」 | **不成立**（對 Qwen3.5-2B 從未發生） | 5.2：實際 GGUF 模板不含 `" thinking"` → 偵測恆 false |
| `6ea26b9`：「Covered by three unit tests」 | **誤導**：三個測試只測 `insert_think_block`，且用同一組常數斷言，無法抓到上述 bug；`template_uses_thinking` / `with_thinking_disabled` 完全無覆蓋 | 5.5 |
| `6ea26b9`：「so the model manager can switch models without a rebuild」 | **未交付**：已提交的 tree 沒有任何 model manager，也沒有任何地方設定 `OVC_LLM_MODEL` | 見下 |
| manifest `selection_note`：「offered by the model manager, which writes … and exports it as OVC_LLM_MODEL」 | **未交付**（同上） | 見下 |
| `6ea26b9`：「ASR prefers model.int8.onnx: identical transcript on test audio」 | **無法驗證**：沒有任何執行紀錄 | 見下 |
| README 對 ASR / LLM / 下載量的描述 | **已過時** | 見下 |
| `985e939`：「Accessibility banner explains the stale-grant state」 | 已交付（banner 存在） | `MainWindow.swift` 內有 `setAccessibilityGranted` / `onRecheckPermission` |

「model manager / OVC_LLM_MODEL 未交付」與「README 過時」與「沒有執行紀錄」的證據：

```
$ grep -rn "OVC_LLM_MODEL|setenv|ModelCatalog|ModelDownloader" --include="*.swift" --include="*.rs" --include="*.sh" . | grep -v "^./rust/core_engine/target"
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelDownloader.swift:13:final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelDownloader.swift:238:            let digest = try ModelCatalog.sha256(of: partialURL)
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelDownloader.swift:354:        guard ModelCatalog.relativePathIsSafe(entry.file) else {
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelDownloader.swift:355:            throw ModelCatalog.CatalogError.unsafePath(entry.file)
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelDownloader.swift:358:            throw ModelCatalog.CatalogError.selectedModel(entry.file)
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelDownloader.swift:361:        let file = ModelCatalog.modelsDirectory().appendingPathComponent(entry.file)
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:33:    /// The bare filename, which is what the engine's `OVC_LLM_MODEL` accepts: it
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:79:enum ModelCatalog {
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:227:/// as `OVC_LLM_MODEL`. Only the filename travels, because the engine validates that and
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:231:    static let engineVariable = "OVC_LLM_MODEL"
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:255:           let entry = try? ModelCatalog.entry(forFile: stored),
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:259:        if let entry = try? ModelCatalog.defaultLLM(),
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:260:           ModelCatalog.isInstalled(entry: entry) {
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:276:            throw ModelCatalog.CatalogError.notSelectable(
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:279:        guard ModelCatalog.relativePathIsSafe(entry.file) else {
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:280:            throw ModelCatalog.CatalogError.unsafePath(entry.file)
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:283:                throw ModelCatalog.CatalogError.notSelectable(
./mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:300:        setenv(engineVariable, currentFileName, 1)
```

已提交的 tree 裡，`ModelCatalog.swift` / `ModelDownloader.swift` **根本不存在**（`git ls-files` 只列出 14 個 Swift 檔，不含這兩個），所以已提交版本裡設定 `OVC_LLM_MODEL` 的地方數量為 **0**。而工作區中新增（尚未提交）的 `ModelCatalog.swift:299` 定義了 `applyToProcessEnvironment()`（內含 `setenv`），**但沒有任何地方呼叫它**：

```
$ grep -rn "applyToProcessEnvironment|LLMSelection" --include="*.swift" mac/macos_app/
mac/macos_app/Sources/OfflineVoiceAssistant/ModelDownloader.swift:357:        guard !LLMSelection.isSelected(entry) else {
mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:229:enum LLMSelection {
mac/macos_app/Sources/OfflineVoiceAssistant/ModelCatalog.swift:299:    static func applyToProcessEnvironment() -> Int32 {
```

即使把這份未提交的工作算進去，引擎的 `OVC_LLM_MODEL` 也不會被設定 → 使用者在 model manager 選的模型**對引擎沒有任何作用**。

**沒有執行紀錄（int8/Qwen3.5 未被實跑過）**——App 自己的 log 停在 10月19 23:23，而且記的是**舊 manifest**：

```
$ tail -6 ~/Library/Application\ Support/OfflineVoiceAssistant/ova.log
23:23:28 accessibility trusted: false (startup)
23:23:29 model cached: asr-sensevoice-small-fp32          ← 舊 manifest：fp32
23:23:29 model cached: asr-sensevoice-tokens
23:23:30 model cached: llm-qwen2.5-1.5b-instruct-q4_k_m  ← 舊 manifest：1.5B
23:23:33 core ready: /Users/joyyang/Library/Application Support/OfflineVoiceAssistant/models
23:23:33 ready
```

`10月20` 當天在 temp 目錄下也沒有任何 build/run log（`find . -newermt "2026-10-19 20:00"` 只找到 scratch 目錄與本 brief）。所以「identical transcript on test audio」這句**沒有任何可查核的證據**，我只能標記為無法驗證。

**README 已過時**（最後一次修改是 `a2f2059`，早於這 4 個 commit）：

```
| ASR (SenseVoice Small, via sherpa-onnx) | Full-precision (fp32) model shipped; the loader falls back to `asr/model.int8.onnx` if it is absent. ...
| Memory | ... Main-process peak RSS: ~1.12 GB with the fp32 ASR (vs ~553 MB with int8) ... To halve this, revert the loader/manifest to `asr/model.int8.onnx` |
| LLM (Qwen2.5-1.5B Q4_K_M) | ... |
| First-launch model setup | ... fetched all models (~1.96 GB with the fp32 ASR + 1.5B LLM) ... |
```

`6ea26b9` 把 ASR 偏好**反轉**成 int8、把預設 LLM 改成 Qwen3.5-2B、把下載量從 ~1.96 GB 降到 1520.39 MB，但 README 三處都還停在舊世界（而且第 10 行寫的方向與程式碼相反，會讓人照著做錯的事）。

---

## 給主要 agent 的待處理清單

依嚴重度排序。

1. **[阻斷] `template_uses_thinking()` 的偵測字串在真實 Qwen3.5 模板上不存在，thinking 抑制機制對新預設模型完全無效。**
   證據：實際 GGUF 的 `tokenizer.chat_template` 內含 `<think>` / `</think>` / `enable_thinking`，但 `' thinking' in tpl` 為 `False`（`has " thinking" : False`）。
   修：(a) 判準改為 `t.contains("<think>")`（或 `t.contains("enable_thinking")`）；(b) `EMPTY_THINK_BLOCK` 改成與模板一致的 `<think>\n\n</think>\n\n`（目前是 `" thinking\n\n</thinking>\n\n"`，開頭多空格、結尾用斜線，與 special token 不符）；(c) 補一個用真實 GGUF 讀 metadata 的測試，避免同類錯誤再次發生。

2. **[阻斷] 三個 think 相關單元測試給了錯誤的信心。** 它們只測 `insert_think_block`，且斷言兩邊共用同一組常數，`EMPTY_THINK_BLOCK` 內容寫錯也測不出來；`template_uses_thinking` / `with_thinking_disabled` 零覆蓋。請把「常數內容」也納入斷言（例如斷言輸出等於 `"<think>\n\n</think>\n\n"`），並補上偵測函式的測試。

3. **[高] `SystemAudioTap.start()` 在 `defaultOutputUID()` 拋錯時洩漏 process tap。** tap 已建立、錯誤直接往外傳、沒有 `deinit` 也沒呼叫 `stop()` → 系統音訊錄製指示燈會永久亮著。修：在 `try Self.defaultOutputUID()` 前用 `do/catch` 包住並呼叫 `AudioHardwareDestroyProcessTap(tapID)`；或加 `deinit { stop() }`。

4. **[高] `strip_owner_clauses()` 會刪掉「只是提到人名」的決議。** 例子：決議「Sarah 明年三月退休」＋待辦「- Sarah: 交接工作」→ 整條決議消失。修：只在該 clause **確實是分派**（含指派動詞／祈使語氣）時才刪，不要只看是否出現人名。

5. **[高] `drop_ownerless_restatements()` 的第二個判準會刪掉「包含決議但多做事」的待辦行。** 例子：決議「決定停用舊版」＋待辦「- 停用舊版後要更新說明文件」→ 整行被刪，連新增工作也沒了。修：區分「幾乎等於」與「只是包含」；只在前者（雙向重疊都高）時刪。

6. **[高] `OVC_LLM_MODEL` 從未由 App 設定，model manager 對引擎沒有任何作用。** 已提交的 tree 裡設定點數為 0；未提交的 `ModelCatalog.swift:299 applyToProcessEnvironment()` 定義了卻**沒有呼叫點**。另外 `6ea26b9` 的「the model manager can switch models without a rebuild」與 manifest 的 `selection_note` 都描述了一個不存在的功能。修：接上呼叫點（啟動時 + `select` 變更時），或先撤回／改寫這兩處宣稱。

7. **[中高] 引擎的 legacy fallback 是靜默的。** 使用者明確選了某個模型但檔案還沒下載時，引擎會安靜地用 1.5B 舊模型，畫面上看不出來。修：fallback 時回報旗標／寫入 `ova.log`，或改為明確報錯。

8. **[中高] `dist/OfflineVoiceAssistant.app` 與 `.dmg` 內含 10月19 的舊引擎**（dylib `de88de31…` ≠ 目前 `0ada4d0e…`；worker `b5d2b124…` ≠ `3fca076e…`），DMG 又是在簽章守門加入之前產生的。修：刪除或用新版重打包（`build_macos.sh` 已優先從 `target/release/deps/` 拷貝，重跑即可）。

9. **[中] `package_dmg.sh` 過度嚴格，擋住正式發行路徑。** 硬性要求 `Authority=Apple Development` + `TeamIdentifier=7S48J3H2N2`，會讓 **Developer ID Application**（正式分發的正常身分）被 `exit 1`，儘管其 DR 不含 cdhash。修：cdhash 判斷維持硬阻擋，Apple Development 降級為警告。

10. **[中] `package_dmg.sh` 的 TCC 檢查查錯資料庫。** 腳本查 `/Library/.../TCC.db`（系統），但使用者層級 App 的 Accessibility 授權記在 `~/Library/Application Support/com.apple.TCC/TCC.db`（使用者）。本機剛好系統 db 有一筆殘留 cdhash 記錄所以能觸發，一般機器上會被 `-r` 擋掉而整段跳過；註解「normally root-only」也與本機事實（`-rw-r--r--`）不符。修：兩邊都查，或改成查使用者 db。

11. **[中] README 與實際行為相反。** 仍寫「fp32 model shipped; the loader falls back to int8」「LLM (Qwen2.5-1.5B)」「~1.96 GB」——`6ea26b9` 已把三者全部改掉（int8 優先、Qwen3.5-2B 預設、1520.39 MB）。第 10 行的方向錯誤會誤導人。修：隨 engine 變更一併更新 README。

12. **[中] `OVC_LLM_MODEL="."` 可通過路徑過濾。** `.` 不含 `/` 也不含 `..`，而 `Path::exists()` 對目錄為 true → 引擎把一個目錄路徑交給 worker。修：過濾時一併拒絕 `.`、純空白、與 `Path::new(v).file_name() != Some(v)` 不符的值。

13. **[中] 啟動視窗內第二次按熱鍵與 HUD 停止鍵都是「無聲失效」。** `toggleDictation()` 的 guard 分支只在 `meeting` 時提示；`stopFromCapsule()` 只看 `meeting`/`dictating`，啟動中兩者皆 false → 按了沒反應，之後錄音還會繼續。修：補提示、並讓停止路徑也認得 `sessionStarting`。

14. **[中] `stopDictation()` 不佔用 `sessionStarting`。** `Core.stopASR()` 還在跑時可以排入新的 `Core.startASR()`，導致**上一段語音的貼上動作發生在新錄音開始之後**。修：加 `stopping` 旗標或重用 `sessionStarting`。

15. **[中低] `SystemAudioTap` 的 converter 與 IOProc 有競爭。** `stop()` 在主執行緒把 `converter`/`inputFormat` 設 nil，IOProc 在 `ioQueue` 讀它們；`AVAudioConverter` 非 thread-safe。另外 input block 只供一次資料就回 `.noDataNow`，取樣率轉換可能因輸入不足而設 error，而 `guard error == nil` 會**整段靜默丟棄**音訊（`error` 變數取出來卻沒被讀過）。修：加入同步（鎖或只在 IOProc 執行緒釋放）、補 `converter.reset()`、把 `error` 記進 log 而不是丟棄。

16. **[中低] `ModelInstaller.items()` 與兩個 shell 腳本對缺 `download` 欄位採 fail-open（`?? true`）。** 目前所有列都有該鍵，屬潛在問題。修：改成預設 `false`。

17. **[低] `file_len()` 同時扮演「存在性探測」與「取長度」兩種角色**（`state.rs:273` / `:278` 只呼叫它來產生錯誤，長度值丟棄）。建議拆成 `require_file()` / `file_len()`，並在「找不到」時把「legacy 也找過」寫進訊息。

18. **[低] `rust/core_engine/target/release/` 頂層的 `.a`/`.rlib`/`.dylib` 停在 10月19 16:04**（`deps/` 裡的是 10月20 00:44 的新產物）。`build_macos.sh` 優先用 `deps/`，所以 app 沒事，但任何直接連結頂層 `.a` 的流程會拿到舊核心。建議清掉頂層副本或統一來源。

19. **[低] 工作區有 9 個未追蹤的新檔（含 `offline_voice_core.h` ABI 變更、`Info.plist` 變更、7 個新 Swift 檔、`segmentation.rs`、2 個腳本）。** 其中 `LLMSelection.applyToProcessEnvironment()` 沒有呼叫點（見第 6 項）。建議先把這批東西整理成一個可審查的 commit，再談下一輪。

20. **[低] 請補上「int8 與 fp32 逐字相同」的證據。** 目前 `ova.log` 最後一筆是 10月19 23:23:33，記的是舊 manifest（`asr-sensevoice-small-fp32` / `llm-qwen2.5-1.5b-instruct-q4_k_m`），temp 目錄下也沒有 10月20 的 build/run log。`6ea26b9` 的「identical transcript on test audio」目前**無法驗證**。請附上時間戳、指令與逐字輸出。

21. **[低] 麥克風與系統音訊以不同 chunk 交錯送進同一個 ASR session，順序不保證、無說話人標記。** `985e939` 的訊息只說「concatenates it with the microphone into one ASR stream」，沒有說明後果。正在進行的 `asr_submit_tagged(..., speaker)` 看來是要補這個洞，請在 commit 訊息裡明確寫出這個限制與解法。
