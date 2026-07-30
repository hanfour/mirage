# D2 鍵盤直通 設計

- **日期**：2026-07-29
- **債務編號**：D2（`2026-07-29-project-review.md` §2，P0）
- **狀態**：設計待實作

## 1. 問題

`EmulatorClient.sendKey(_:down:)` 存在且實作正確，但**全碼庫零呼叫端**。使用者在鏡像視窗
裡按任何鍵，guest 都收不到。

路徑斷在這裡：

```
MirrorMTKView.keyDown → keyCode(from:) → .key(chars)
  → Coordinator → KeymapController.handleKeyDown(code)
    → engine?.apply(.keyDown(code))    ← engine == nil 時整條 optional chain 回 nil
      → emit(nil)                      ← 按鍵在此被丟棄
```

兩種丟棄情形：

1. **無 keymap profile**：`engine` 是 nil，`emit` 收到 nil，什麼都不做。
2. **有 profile 但該鍵沒被綁**：`KeymapEngine.apply` 回傳的快照不含任何變化，
   `emit` 一視同仁地送出（或不送），按鍵的「鍵盤語意」從未被表達。

第 2 種比第 1 種更常見——指標遊戲幾乎都會有 profile。

**這筆債的特殊之處**：它是 §0 那四類誤診中唯一「任何文件都沒提過」的一筆，
是靠結構性檢查（公開 API 有沒有呼叫端）而不是關鍵字掃描找到的。

## 2. 前置實測：三條路徑哪一條真的送得到

`KeyboardEvent` 有三個互斥欄位，proto 說「only keyCode, key, or text can be set」：

| 路徑 | proto 的說法 |
|---|---|
| `key`（W3C 字串） | 版面感知；**只保證可列印 ASCII [32,127) 被正確翻譯**，且「Not all documented keys are understood by android」 |
| `keyCode` + `codeType`（支援 `.mac`） | 送實體鍵碼，emulator 走 chromium 對照表翻成 evdev |
| `text`（utf8 整串） | 適合大量文字；proto 說 >1kb 會爆鍵盤緩衝，建議改用剪貼簿 |

**不採信 proto 的保守說法，實測。** 儀器用 `adb shell getevent -l` 直接讀 guest kernel 的
evdev 事件流——**不是**「開個文字框打字看看有沒有字」，因為後者是代理指標：沒出現字可能
是鍵沒送到、可能焦點不在輸入框、可能輸入法沒起來，三種原因看起來一模一樣。

在 `bench`（`emulator-5558`）上量測，連續兩次結果完全一致：

| 鍵 | 期待的 evdev | `key` 路徑 | `keyCode`+`.mac` |
|---|---|---|---|
| `a` | KEY_A | ✅ | ❌ |
| Enter | KEY_ENTER | ✅ | ✅ |
| Backspace | KEY_BACKSPACE | ✅ | ✅ |
| Tab | KEY_TAB | ✅ | ✅ |
| Escape | KEY_ESC | ✅ | ✅ |
| ArrowUp | KEY_UP | ✅ | ✅ |
| Space | KEY_SPACE | ✅ | ✅ |
| GoBack | KEY_BACK | ✅ | — |
| GoHome | KEY_HOME | ✅ | — |
| AppSwitch | KEY_APPSELECT | ✅ | — |

**三個結論**：

1. **`key` 路徑十個鍵全通**，包含 proto 警告過的非可列印鍵。proto 的說法過度保守。
2. **`keyCode`+`.mac` 送不出 `a`**——這是 proto3 的坑而非 emulator 的：mac 虛擬鍵碼 `a` 是 **0**，
   而 proto3 的 0 是欄位預設值、不會被序列化，emulator 收到的是「keyCode 未設」。
   用 `s`（鍵碼 1）對照即可確認：`s` 正常送達。
3. **量測過程本身有兩個假陰性**，值得記下來：
   - Tab 第一輪是 ❌，原因是 `getevent` 暖機時間只給 0.4 秒；改 0.8 秒後穩定 ✅。
   - GoHome 第一輪是 ❌，原因是**我 grep 的 evdev 名稱猜錯了**（實際是 `KEY_HOME` 不是
     `KEY_HOMEPAGE`）。對照組 `key="Home"` 產生零事件，反證 `GoHome` 才是正確的輸入值。

   「沒看到我期待的訊號」不等於「東西沒送到」。兩個 ❌ 都是量測錯誤，不是功能問題。

**設計採用**：**只走 `key` 路徑**。不需要 `.mac`、不需要鍵碼對照表，也就完全避開 keyCode=0 那顆地雷。
既有的 `EmulatorClient.buildKeyEvent` 已經是這條路，不必改。

## 3. 設計決定

| # | 決定 | 理由 |
|---|---|---|
| D-1 | **profile 沒綁的鍵才直通** | 使用者能一邊用搖桿一邊在遊戲聊天框打字。只在「無 profile」時直通的話，有 profile 就完全不能打字——而指標遊戲幾乎都有 profile |
| D-2 | 涵蓋可列印字元 + 編輯鍵（Enter/Backspace/Tab/方向鍵）+ Android 實體鍵 | 少了 Enter/Backspace，「能打字」實際上不能用 |
| D-3 | **帶 ⌘ 的組合鍵一律不送** | Android 沒有 ⌘；且 ⌘C/⌘V 已有剪貼簿橋接負責，送過去會貼兩次。規則單一、使用者好預測 |
| D-4 | **Esc → `GoBack`** | 實測產生 `KEY_BACK`。P1-e 設計文件已寫明「不綁 Esc（Esc 在 guest 是返回鍵）」，此決定兌現那個意圖 |
| D-5 | GoHome / AppSwitch 走**選單列**，不綁按鍵 | 每個候選鍵都有衝突：⌘ 已排除、F1–F3 在 macOS 預設是亮度/音量、⌃A/⌃E 在文字欄位有既有語意。選單列零衝突且可發現 |
| D-6 | 引擎公開既有的 `isMapped` 述詞，不改 `apply` 簽章 | 引擎裡已經有這個判定式（還有 `unmappedCount` 在數）。改 `apply` 回傳 enum 更「精確」，但會動到所有既有引擎測試——為一個布林值付這個代價不划算 |
| D-7 | NSEvent→W3C 的換算做成 **MirageCore 的純函式** | 比照 `ForegroundParser`／`ActivationDecider`／`StreamSize` 的既有慣例：App 層不可單元測試，就把可測的部分抽出來。輸入取 NSEvent 的**欄位**而非 NSEvent 本身 |

## 4. 架構

### 4.1 新增：`MirageCore/Keymap/KeyTranslate.swift`（純函式）

```
public enum KeyTranslate {
    /// NSEvent 的欄位 → 要送給 guest 的 W3C key。nil = 不直通。
    public static func w3c(virtualKey: UInt16,
                           characters: String?,
                           hasCommand: Bool) -> KeyCode?
}
```

判定順序：

1. `hasCommand` → `nil`（D-3）
2. 特殊鍵查表（以 macOS 虛擬鍵碼為鍵，**不是**字元——`charactersIgnoringModifiers`
   對 Enter 給 `"\r"`、對方向鍵給私用區字元，不能用）
3. 其餘 → `.key(characters)`，維持現行行為（版面感知）

回傳型別沿用既有的 `KeyCode`——`GoBack` 這類 Android 專屬值同樣包成 `.key("GoBack")`，
因為 `EmulatorClient.buildKeyEvent` 就是把 `.key(w3c)` 的字串直接放進
`KeyboardEvent.key`。**不新增型別**：Android 專屬值與一般 W3C 值在傳輸層是同一件事，
在型別上分家只會讓 `buildKeyEvent` 多一個 switch。

特殊鍵表（虛擬鍵碼 → W3C）：

| 鍵 | kVK | W3C |
|---|---|---|
| Return | 36 | `Enter` |
| Delete | 51 | `Backspace` |
| Tab | 48 | `Tab` |
| Escape | 53 | `GoBack` ← D-4 |
| ArrowLeft/Right/Down/Up | 123/124/125/126 | `ArrowLeft`/`ArrowRight`/`ArrowDown`/`ArrowUp` |

**為什麼用虛擬鍵碼當表的鍵**：它與鍵盤版面無關，是「哪顆實體鍵」；而字元會隨版面變。
可列印字元走字元路徑（要版面感知），特殊鍵走鍵碼路徑（要版面無關）——兩者要的東西不同。

### 4.2 修改：`KeymapEngine`

`isMapped(_:)` 由 `private` 改 `public`，更名 `handles(_:)`（呼叫端讀起來是問句）。
行為零改變。

### 4.3 修改：`KeymapController`

```
handleKeyDown(code):
    if engine?.handles(code) == true  → emit(engine.apply(.keyDown(code)))   // 現行路徑
    else                              → Task { await client.sendKey(code, down: true) }
handleKeyUp(code): 同上，down: false
```

> **更正（2026-07-30，D6）**：上面那段虛擬碼的 `Task { await client.sendKey(...) }`
> **已不是現行實作，也不該被照抄**。每個事件各開一個 unstructured Task 正是 D6 的
> 本體——down 與 up 對調就是 guest 永久卡鍵，而且沒有自癒路徑。
>
> 現行實作：`KeymapController` 持有 `MirageCore.InputQueue`（一條 `AsyncStream` ＋
> **單一**消費者 Task），直通鍵走 `queue.key(code, down:)`、觸控快照走
> `queue.touches(_:)`。順序保證來自「只有一條消費路徑」這個結構，不是靠序號或重試。
> 佇列由 `AppModel` 持有並注入，**一台 guest 只有一條**——tap、鍵盤、觸控共用它，
> 否則各自一條佇列之間仍然沒有順序。
>
> 亂序已用 `InputQueueTests` / `KeymapControllerRoutingTests` 確定性重現過：修之前
> 實測到 `["k up", "k down"]`（放開先於按下）與 `["touch []", "touch [1]"]`。

修飾鍵（`handleFlagsChanged`）維持現狀只餵引擎——Shift/Control/Alt 單獨送給 guest
沒有意義，而組字用的 Shift 已經由 `charactersIgnoringModifiers` 反映在字元上。

### 4.4 修改：`MirrorMTKView.keyCode(from:)`

改為呼叫 `KeyTranslate.w3c(virtualKey:characters:hasCommand:)`，本身不再有判斷邏輯。

### 4.5 修改：`MenuBarController`

新增三個項目：返回 / 主畫面 / 最近任務 → 各自 `client.sendKey(.key("GoBack"|"GoHome"|"AppSwitch"), down:)`
（送 down 再送 up）。

## 5. 資料流

```
NSEvent ──► MirrorMTKView.keyDown
              └─► KeyTranslate.w3c(...)  ─── nil ──► 丟棄（⌘ 組合）
                        │
                     KeyCode
                        ▼
              KeymapController.handleKeyDown
                        │
          ┌─────────────┴─────────────┐
   engine.handles == true        否則
          ▼                           ▼
   KeymapEngine.apply            client.sendKey
   → TouchFrame                  → KeyboardEvent(key:)
   → client.sendTouches          → guest evdev
```

## 6. 錯誤處理

沿用 `sendKey` 既有語意：`channelBox == nil`（未連線）時靜默不送，與 `sendTap`／`sendTouches`
一致。不新增錯誤路徑——按鍵送不出去時使用者會直接從畫面看出來，加 banner 只是噪音。

**已知不處理**：按鍵重複（`NSEvent.isARepeat`）。macOS 會對按住的鍵重送 keyDown，
本設計照送——Android 端本來就預期連續 keydown 表示重複。若實測發現重複過快，
再加節流；**在量到問題之前不預先優化**。

## 7. 測試

| 層 | 測什麼 | 怎麼測 |
|---|---|---|
| `KeyTranslate` | ⌘ 過濾、特殊鍵對照、一般字元穿透、nil 輸入 | MirageCore 純單元，逐行覆蓋 |
| `KeymapEngine.handles` | 已綁/未綁鍵的判定 | 既有測試檔擴充 |
| `KeymapController` 分流 | 綁到的走觸控、沒綁的走 sendKey | 假 client 記錄呼叫（比照 `MockAudioTransport.cancelCount` 慣例） |
| 活體 | 鍵真的到達 guest | opt-in（`LiveGate`），儀器沿用 `getevent`——與本文件 §2 同一套 |

**活體測試刻意沿用 getevent 而非「打字看畫面」**，理由同 §2：後者分不出三種失敗。

## 8. 不做什麼（YAGNI）

- **不做 `text` 路徑的大量文字輸入**。剪貼簿橋接已經涵蓋這個需求，proto 自己也這樣建議。
- **不做 keymap profile 的 key→key 綁定**。那需要改 profile schema 與編輯器，屬 D5 範圍。
- **不做按鍵重複節流**。見 §6。
- **不碰 `keyCode`／`.mac` 路徑**。實測顯示 `key` 已足夠，多一條路就多一個要維護、要出錯的地方。

## 9. 驗收

1. `swift test` 全綠，`KeyTranslate` 逐行覆蓋。
2. 分流測試：有 profile 時，綁到的鍵**不**觸發 `sendKey`；沒綁到的鍵觸發。
3. ⌘ 組合鍵不觸發 `sendKey`。
4. 活體（opt-in）：`a`、Enter、Backspace、Esc 四個鍵在 `getevent` 中出現對應的
   `KEY_A`／`KEY_ENTER`／`KEY_BACKSPACE`／`KEY_BACK`。
5. `app/scripts/ci.sh` 三道閘門全過。

**不列為驗收**：真實打字手感、選單列項目的目視。那些屬於
`2026-07-29-project-review.md` **§8 D 節**點名的第三類——「阻礙已消失，但沒人回頭驗」。
它們應該被實際驗一次，而不是再記一筆 pending 然後每輪都被跳過。
