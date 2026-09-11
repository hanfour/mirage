# Mac IME 人工驗收清單（Task 8 待完成部分）

**目前尚未證明真 Mac IME→LINE 已修好。** 這份清單要由人按實體鍵。
已完成的是 Core／真 view 的合成事件測試、故障注入、AppKit 視窗幾何、診斷與精確欄位工具。
不要用直接呼叫 insertText、osascript、adb input text、UiAutomator.setText 或 Cmd-V
代替以下 IME 案例。工具內的 UiAutomator **只 dump／讀欄位，不輸入**。

## 1. 先準備與保留原稿

1. 先普通 EditText，完成後才到 LINE。同一機器與固定節流設定逐案測；記錄 macOS、
   Mac 輸入來源／鍵盤配置、Android IME 語言、emulator／LINE 版本。之前的版本結果不能自動沿用。
2. 普通欄位用 Android 系統設定搜尋頁：
   package `com.google.android.settings.intelligence`，field
   `com.google.android.settings.intelligence:id/open_search_view_edit_text`，空值 hint `Search settings`。
   LINE 用 `jp.naver.line.android`、`jp.naver.line.android:id/chat_ui_message_edit`。
3. 僅用授權且可清理的草稿。原稿非空先由人保存到本機備份並核對；原剪貼簿另存、結束還原。
   不碰送出按鈕。先在普通欄位確認候選 Return 的 guest key trace 是零，
   LINE 還需確認目前設定不會以 Enter 發送；無法確認時 LINE Return 案列 BLOCKED。
4. 每案各自清理、重新點中草稿並確認游標；不要在錯誤稿上重試。
   用 Android 畫面選單手動全選／刪除即可。此步是前置，不能當 Mac IME 驗收。
5. 左下「文字輸入」選「Mac 文字」或無 profile 的自動模式。設定先固定候選 250 ms，
   它不是安全下限。套用後關閉面板、重新點欄位；確認沒有暫停／錯誤。
   遇到錯字立刻暫停、存 FAIL。新政策必須開新 run，不刪舊 FAIL。

## 2. 開啟診斷與背景觀察（不要組字時切去 Terminal）

先退出舊 Mirage，再打包成 `.app`、用 `open` 啟動一個新的 Mirage 行程。
以下路徑只是本輪例子；**每輪換新名稱**，trace／snapshots／report 都拒絕覆寫。

```sh
cd app
mkdir -p /private/tmp/mirage-ime-human-01
APP=$(./scripts/package_app.sh /private/tmp/mirage-ime-human-01 debug | tail -1)
open -n --env MIRAGE_IME_DIAGNOSTICS=/private/tmp/mirage-ime-human-01/trace.jsonl \
  --env MIRAGE_TEXT_SETTLE_MS=250 "$APP"
```

⚠️ 不要從 Terminal 直接執行 `.build/debug/MirageApp`。沒有 bundle 的執行檔會被系統登記成
`ApplicationType = BackgroundOnly`、沒有 bundle ID，也不會變成前景 app（2026-09-11 實測，
`lsappinfo` 可查），鍵盤與輸入法的輸入會送到 Terminal 或其他程式。上面的 `open` 啟動方式實測
是 `Foreground`、`com.mirage.app`，而且兩個環境變數都有傳進行程。

另一個 Terminal 在你回到 Mirage 前啟動 180 秒背景觀察。腳本會列出 sample 編號與
valid／INVALID，保存 fresh XML 解析的精確文字與欄位裁切圖。查詢失敗、未聚焦都無效，
不能當空欄位。腳本不會幫你點擊或清理，也不會讀 clipboard 作證據。

```sh
./scripts/verify_host_ime.sh watch /private/tmp/mirage-ime-human-01/settings \
  --package com.google.android.settings.intelligence \
  --field com.google.android.settings.intelligence:id/open_search_view_edit_text \
  --empty-label 'Search settings' --seconds 180
```

LINE 的另一輪換成：

```sh
./scripts/verify_host_ime.sh watch /private/tmp/mirage-ime-human-01/line \
  --package jp.naver.line.android \
  --field jp.naver.line.android:id/chat_ui_message_edit --seconds 180
```

每次開始組字前停約 5 秒；出現 marked／候選時也停至少 5 秒；確定後停約 5 秒。
這是讓獨立觀察器取得非重疊樣本，**不是修改產品的消費節流**。
若 dump 太慢、沒有完全落在 marked 期間的樣本，該案 INVALID，另開一案補觀察。
Mac 截圖由人用系統截圖快捷鍵擷取鏡像＋候選窗，注意避開私密對話。

## 3. 實體按鍵、預期與失敗

先 Apple 拼音，再 Apple 注音，各自獨立案例；將實際按鍵序列寫進 case，不能只寫「打中文」。
候選排序會依個人詞庫不同，記錄你按的方向／數字鍵；先確認候選字，再確定。

| 案例 | 人要做的動作 | 預期／失敗判準 |
|---|---|---|
| 拼音組字 | 切 Apple 拼音，按 `z h o n g w e n`；停留。用 Space／方向鍵選到「中文」，需要 Return 時只按一次 | marked 在 Mac 浮層；停留期間 guest 原文完全不變；確定後只有「中文」一次。候選鍵／Return 有 guest raw key 即 FAIL |
| 注音組字 | 標準注音依鍵盤標示按 `ㄓ ㄨ ㄥ`、第一聲空白、`ㄨ ㄣ ˊ`，停留，選「中文」再 Return；標準鍵位通常是 `5 j / Space j p 6 Return`，先用鍵盤檢視器核對配置 | 同上；輸入法若實際分兩筆確定，先把這種模式的預期提交分段記清楚，不能事後把重複貼上改稱分段 |
| 候選改選 | 組字後用 Down／Up 改候選，再選回預定文字，停留後確定 | 只有最後確定字進 guest；上下鍵不移動 Android 游標、不觸發遊戲 |
| 取消 | 組出尚未確定的「中」，停留後 Escape | Mac marked 消失；guest 與 before 完全相同，沒有 commit／GoBack；本機草稿可保留，不能自動貼回 |
| 中英切換 | Mac 拼音／注音與 ABC 各切一次，分別用實體鍵輸入；再切回中文 | 沒有殘留 modifier／key-up、沒有重播舊組字；每段精確符合事先期望 |
| 同字次數 | 獨立稿中把「你好」分兩次確定 | 恰為「你好你好」，兩個不同 commit ID；不能用這案證明異字順序 |
| 異字 burst | 事先列 `中01`、`文02`…共 20 筆，各筆實體鍵確認，保存預定 commits 陣列 | 每筆順序及最終完整字串完全符合；報告記錄實際 dispatch 起點間距，不只設定值 |
| 中間插入 | 人先種 `LEFTRIGHT` 並核對，將 caret 放 LEFT 後，再從 Mac IME 確定「中文」 | `LEFT中文RIGHT`；尾端追加、丟前後綴都 FAIL |
| 選取替換 | 人先種 `LEFToldRIGHT` 並核對，只選 old，有可見高亮，再用 Mac IME 確定「中文」 | `LEFT中文RIGHT`。若用 Copy 證明 old，Copy 後須重新選取；LINE 曾因 Copy 收合選取而 FAIL |

位置案先保存 before（文字與 selection／caret 的畫面），才組字。工具讀不到 selection，
所以**高亮／caret 照片要另外保存**；不能靠 final 字串冒充前置定位證明。

六組 corpus 同樣由人實際輸入，逐案重設：`Mirage IME 中文測試 42！`、`你好你好`、
`你好🙂`、`é é`、`👩🏽‍💻👨‍👩‍👧‍👦`、`Mirage ASCII 42`。

- 中文部分使用上述真 IME；ASCII 用 ABC 實體鍵。
- NFC é：ABC 下實體 `Option+e`、放開、`e`。NFD 的 e＋U+0301 可用系統 Unicode Hex Input
  依序輸入 U+0065、U+0301（按住 Option 輸入各四位碼後放開）。先記錄實際輸入來源與鍵序。
  若來源本身正規化成另一序列，記錄來源限制／FAIL，不能把期望改成看起來一樣。
- emoji 用真正系統字元檢視器（實體 `Control+Command+Space`），選指定膚色、職業、家庭序列；
  記錄實際選字操作。找不到對應字形、callback 被取消或不能維持焦點，就記 BLOCKED／FAIL。
  不改用貼上或程式直接呼叫 insertText 補過。這裡也要驗證系統選字入口是否受到焦點取消影響。
- 純 ASCII／Unicode 控制案用 `kind: "unicode-control"`，可沒有 marked checkpoint；它們不能
  代替 `kind: "ime"` 的中文組字驗收。對每筆實際確定的單位，**操作前**列出預期 commits。

## 4. 候選窗的位置（真正未驗的部分）

有未確定文字時，依序在鏡像上／中／下方點位重新起一案，觀察浮層與系統候選。
再拖標題列移動約 100 points、縮小／放大視窗、進出全螢幕；有另一螢幕時移過去，
分別記 1×／2×。每個動作後續打一個組字鍵，必要時另起組字（全螢幕失焦可取消）。

預期候選窗貼著本機 marked glyph、仍在可見區，移窗後不留在舊位置、不多乘 backing scale。
它是點擊附近的**近似錨點**，不是 Android caret 的精確位置；Android 自己移 caret 不會被追蹤。
浮層不能吃掉滑鼠點擊或搶焦點，guest 欄位裁切圖不應有尚未確定的 marked 字。
若候選窗有偏移，保存 Mac 圖與 trace 的 `candidate-rect`，量偏差；不要因 NSWindow 測試零誤差
就勾這項通過。全螢幕取消本身可接受，留下舊窗／舊字／自動提交不可接受。

## 5. 選 checkpoint、精確比對

一案一份 JSON。以下例子先存為 case.json，再把 sample 編號換成你實際取得的有效樣本，
**expected／commits 應在操作前決定**。before 是組字前最後一個穩定樣本；preedit 的整個觀察
區間必須在 marked 開始之後、commit 之前；after 的觀察必須在 result 之後。original 必須是清理／種前綴前的原稿樣本；
restored 是本案結束、由人還原原稿後的樣本，兩者也要逐碼位相同（不能只勾聲明）。

```json
{
  "kind": "ime",
  "humanPhysicalKeys": true,
  "inputMethod": "Apple Pinyin — 記錄實際鍵盤配置與 macOS 版本",
  "physicalSequence": "z h o n g w e n；實際候選選字鍵；Return",
  "package": "jp.naver.line.android",
  "field": "jp.naver.line.android:id/chat_ui_message_edit",
  "settleMS": "250",
  "original": "0001",
  "restored": "0010",
  "before": "0003",
  "preedit": ["0005"],
  "after": "0008",
  "expected": "中文",
  "commits": ["中文"],
  "noMessageSent": true,
  "originalDraftPreserved": true
}
```

`humanPhysicalKeys` 是你的聲明，工具不能鑑定按鍵是否由人產生；未實際做不能填 true。
取消案為 `commits: []`、expected 等於 before。不要截短錯誤時段以藏掉重送或 guest Enter。
完整 trace 要保留，驗收器只依明確 before／after 區間計算這一案。

```sh
./scripts/verify_host_ime.sh verify \
  --case /private/tmp/mirage-ime-human-01/case.json \
  --snapshots /private/tmp/mirage-ime-human-01/line \
  --trace /private/tmp/mirage-ime-human-01/trace.jsonl \
  --output /private/tmp/mirage-ime-human-01/result.json
```

exit 0 是該案例與該配置的 PASS；1 是 FAIL；2 是證據 INVALID 或無法建立新報告。
報告有逐碼位 expected／observed、trace hash、實際 dispatch 間距；不把 clipboard 或 RPC 當
欄位證據。即使 all RPC OK，精確欄位不符仍是 FAIL。工具不調政策、不覆寫舊報告。

## 6. 手動失敗復原與收尾

在可清理的普通欄位組到一半切去別的視窗，再回來：不應自動提交舊字；面板仍能保留草稿。
把間隔改成 `0`／`abc` 後另輸入測試字：應明確拒收、保留字串，不能 Paste；改回正值只影響
後續提交，舊失敗稿不能自行送出。人工按「暫停文字提交」、關閉／重開面板：不能解除暫停或重播。

Paste timeout／回讀 mismatch／斷線／送出時失焦／外部 clipboard 衝突已用隔離 transport 驗證，
不用在真 LINE 強造斷線。結果不確定時先人工核對欄位；面板的「核對」勾選只是你的判斷，
不是機器驗證。手動恢復不重送；複製保留稿會先暫停 clipboard 同步。

完成後由人清掉測試稿、恢復並核對原稿與原 clipboard；記錄沒有新增訊息。
遊戲有 profile 時回到自動／映射模式，驗原鍵位與放開正常；Unity 原有數字案例另外手動回歸。
未做的項目（尤其另一螢幕、Unity、某種 Mac 輸入來源）逐項留 pending，不能以離線 CI 勾完。
