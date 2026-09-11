# Mac IME 前置：普通 EditText 與 LINE 草稿的文字提交通道（2026-09-11）

**剪貼簿＋一次 Control+v 能把本輪全部 Unicode 測試字串精確放進 LINE 草稿框；
但「RPC 返回後立刻換下一筆 clipboard」不可靠。** 不同字串連續提交時，0 ms 額外間隔
在普通 EditText 與 LINE 都出錯；100／250 ms 本輪通過。Android `KEYCODE_PASTE` 在本輪
所有已測配置通過，但它包含 adb 往返時間，不能拿「額外間隔 0」說它零延遲或天然有消費 ACK。

這份結果**保留設計 §2.2 的單次提交主路候選，否證無節流的連續提交版本**。
它不代表 Mac IME 接線已修好，也不把一次有限測試當成所有 app／負載下的穩定性保證。

## 1. 範圍、條件與儀器

- 依 [Mac IME 設計 §7.1](../docs/specs/2026-09-11-macos-ime-text-input-design.md) 先驗通道，
  沒有實作 NSTextInputClient、marked text 浮層或候選窗 UI。
- 同一 emulator-5554／gRPC 8554，**37.1.11.0，build 15917651，Android API 35**。
  Android IME 為 `com.google.android.inputmethod.latin/com.android.inputmethod.latin.LatinIME`。
  未切換 Android IME，也沒有完整枚舉其語言 subtype；不從 LatinIME 類名推定是英文輸入法。
- **普通 EditText 先跑完，才進 LINE 對照。** 本機沒有 Android build-tools、platforms 或 JDK，
  因此使用系統設定搜尋頁的原生 `android.widget.EditText`，不是 WebView，也沒有下載工具鏈
  或假稱建立了獨立 fixture APK。搜尋頁本身仍有 app 的搜尋／選單行為，不能外推到所有 EditText。
- 普通欄位：`com.google.android.settings.intelligence:id/open_search_view_edit_text`。
  空欄位的 accessibility text 顯示 hint `Search settings`，只在已清理的前置狀態將此已知
  placeholder 視為空；原始 node text 同時保存，測試字串皆不等於 placeholder。
- LINE **26.14.0／261400121**，已登入、原草稿為空；目標為
  `jp.naver.line.android:id/chat_ui_message_edit`，class 亦為 `android.widget.EditText`。
  不按 Enter、Send 或任何發送按鈕。只保存欄位裁切圖與測試文字，不保存真實對話內容。
- 使用 Python gRPC 直接探測與擬議 Swift 實作相同的 proto 操作；這不是 Mac 輸入法端到端測試。
  普通欄位與 LINE 使用相同 corpus／通道順序，每個案例獨立清空、驗焦點再送字。

## 2. 四條通道與判準

| 通道 | 實際動作 |
|---|---|
| `text` | 一個只設 `KeyboardEvent.text` 的 sendKey RPC；其他欄位維持預設，不混設 key/keyCode |
| `ctrl_v` | gRPC setClipboard → 有限時間 getClipboard 比對 → W3C Control down、v down、v up、Control up |
| `android_paste` | 同樣 set/getClipboard，然後 `adb shell input keyevent KEYCODE_PASTE` |
| `ui_paste` | 同樣 set/getClipboard，重播 Android 原生長按手勢，再找精確的 Paste／貼上選單項目並點選 |

每案先用**獨立的 Android Ctrl+A／DEL** 清欄位，重新讀回目標 package、resource-id、class、
`focused=true` 與空值；不在同一草稿上連續嘗試不同通道。基本案例每次只提交一整串。
整個測試程式沒有「貼上失敗後再貼一次」的分支；錯誤後最多觀察欄位及釋放合成按鍵。
本輪沒有發生 paste RPC timeout，故不宣稱已活體驗證逾時分支。

**PASS 只看目標欄位的實際文字與焦點**：UIAutomator 回傳文字必須與預期逐 Unicode scalar
相等，不做 NFC/NFD 正規化、不把顯示相似當成相等。另存欄位裁切截圖。
clipboard 回讀與 RPC OK 只記為傳輸前置，從未拿來取代欄位內容。

## 3. 單次整串：六組字串、兩個目標的完整矩陣

| 案例 | 實際字串 | 普通 EditText：text / Ctrl+v / Android Paste / UI Paste | LINE：text / Ctrl+v / Android Paste / UI Paste |
|---|---|---|---|
| 混合 | `Mirage IME 中文測試 42！` | 不符／通過／通過／受阻 | 不符／通過／通過／受阻 |
| 重複內容 | `你好你好` | 不符／通過／通過／受阻 | 不符／通過／通過／受阻 |
| 中文＋emoji | `你好🙂` | 不符／通過／通過／受阻 | 不符／通過／通過／受阻 |
| 重音 | `é é`（U+00E9、空白、U+0065、U+0301） | 不符／通過／通過／受阻 | 不符／通過／通過／受阻 |
| ZWJ | `👩🏽‍💻👨‍👩‍👧‍👦`（膚色、ZWJ、家庭序列均保留） | 不符／通過／通過／受阻 | 不符／通過／通過／受阻 |
| ASCII 對照 | `Mirage ASCII 42` | 不符／通過／通過／受阻 | 不符／通過／通過／受阻 |

每個目標 24 案：12 通過、6 欄位不符、6 原生選單操作受阻。
**Control+v 與 Android Paste 的六種字串，本輪沒有單次失敗案例。**
重複內容在本矩陣是一筆 `你好你好`；同字串多筆提交另由下一節的 20 筆測試驗證。

`text` 的實際欄位結果：混合、重複、emoji、ZWJ、ASCII 皆未留下文字；重音案例在普通
EditText 留下 ` e`，在 LINE 只留下空白。RPC 均回 OK。這不是「text 完全不會產生任何字元」，
也不是只測中文後推論 ASCII；**本輪六案都未完整到達**，不適合作本案整串提交主路。
內部轉鍵／緩衝為何產生這組結果未定位，亦未量 Android IME 的組字 buffer；空草稿不能
證明鍵事件完全沒有到 guest。這條路沒有達成本案「直接插入確定文字」的要求，不能把
字串欄位支援 UTF-8 當成 Unicode 插入保證。

### 原生長按貼上為什麼記「受阻」

兩個目標各六案都已成功設定／回讀 clipboard，但長按後沒有找到可點的 Paste 項目，
因此沒有執行貼上，沒有最終貼上字串可判成敗。另看過普通欄位的實際長按畫面，也未見選單；
LINE 受阻時的畫面同樣未見可確認的 Paste 項目。

這只是**本次手勢／選單路徑受阻**，不能推成 LINE 禁用貼上、Unicode 不支援，亦不能把這條
手動退路寫成已驗過。UI 手勢由 adb 重播，不冒稱每案由人工操作。

## 4. 連續提交：能貼一次不等於可以立刻改下一筆 clipboard

每個目標另外測兩條程式化貼上通道、三個額外間隔、兩種序列，共 12 案；每案獨立清欄位。
每案提交 **20 筆**：

- 同字串：`你好` × 20，預期 40 個中文字，不得被同值去重。
- 不同字串：`測00🙂 ` 到 `測19🙂 `，必須順序完整、每個編號恰好一次。

burst 中不穿插 UIAutomator 讀回；只在 20 筆都送完後讀欄位，避免量測動作替提交偷偷節流。
每筆 setClipboard 都讀回正確值才送一次 Paste。額外 sleep 放在上一筆交易返回之後，
**0 ms 不等於沒有 RPC／adb 成本**。

| 通道 | 額外間隔 | 普通 EditText：同字／異字 | LINE：同字／異字 | 異字實際提交起點間隔中位數：EditText／LINE |
|---|---:|---|---|---:|
| Control+v | 0 ms | 通過／**不符** | 通過／**不符** | 3.047／2.446 ms |
| Control+v | 100 ms | 通過／通過 | 通過／通過 | 106.116／105.419 ms |
| Control+v | 250 ms | 通過／通過 | 通過／通過 | 259.742／258.709 ms |
| Android Paste | 0 ms | 通過／通過 | 通過／通過 | 75.489／50.204 ms |
| Android Paste | 100 ms | 通過／通過 | 通過／通過 | 222.988／158.928 ms |
| Android Paste | 250 ms | 通過／通過 | 通過／通過 | 405.212／321.965 ms |

Control+v 的 0 ms 異字案例，預期是 00 到 19 各一筆，實際是：

- 普通 EditText：`測03🙂 `＋`測19🙂 ` 重複 19 次。
- LINE：`測12🙂 `＋`測19🙂 ` 重複 19 次。

兩案 **20 次 clipboard 回讀都相符、所有 RPC 都 OK，欄位仍然錯誤**。
這個形狀符合「後續 clipboard 已覆寫、先前 Paste 才被目標消費」的競態解釋；
本輪沒有做底層時序追蹤，故不指認特定執行緒或把它說成底層 ACK 機制已被證明。
**同字串測試即使通過，也無法區分貼到的是哪一次相同 clipboard，不能單獨作穩定性證據。**

100／250 ms 每個配置各跑一組 20 筆，這些配置本輪通過；它們不是已確立的通用安全下限。
Android Paste 的 0 ms 實際仍比 gRPC Control+v 慢很多，沒有等速比較，不能據此判定其
keycode 本身消除了競態。

## 5. 未完成項目、量測限制與現場清理

- **中間插入／選取替換未驗**：普通 EditText 位置測試的執行權限請求遭拒，沒有執行，
  也沒有換另一條命令繞過；LINE 的位置測試未接著嘗試。這份資料不能替它們蓋通過章。
- LINE 啟動時一次 UI dump 回傳 null root，**那時未進行 LINE 案例注入**。確認可讀後才開始。
  同時加固探針：每次先移除舊 XML，要求新的 dump 成功，避免把舊檔當新欄位。
  普通 EditText 初版未有這道防舊檔保護，保留其原始程式與 SHA-256，不重寫歷史；
  單次結果有逐案截圖，核心結果也在使用加固探針的 LINE 獨立重現。
- 診斷回報是**欄位文字的精確讀回**，不是接收者收到訊息；本題沒有也不需要發送聊天訊息。
  程式沒有 Enter／Send 操作；結束時 LINE 原本的空草稿已恢復空白，guest clipboard 已還原。
  測試前後兩個可見、非標題／日期的對話 TextView 內容指紋一致，檢查要求非空基線；
  不使用「0 筆對 0 筆」的恆真比較，也不聲稱稽核了整個伺服器聊天歷史。
- 沒有實作 Mac IME UI，沒有驗注音／拼音的候選窗、marked text、Escape／Return 分流，
  也沒有驗 Mirage ClipboardWatcher 與文字交易同時執行的競態。這些仍屬後續實作與驗收。

## 6. 對設計的影響

1. **保留剪貼簿＋Control+v 作 Unicode 單次提交主路候選**：LINE 六種字串精確到達，
   不是僅有 clipboard echo。`KeyboardEvent.text` 不提升為主路，連本輪 ASCII 整串也不完整。
2. **2.2 的消費等待必須成為實作條件**：不能把串行 RPC 返回或 clipboard 回讀當成目標已
   消費。無額外間隔的多筆版本已被否證；100／250 ms 可作後續固定配置的測試起點，
   不能稱消費 ACK。若無法維持驗明的節流條件，就要保留待送佇列／限制下一次 clipboard
   覆寫，或重新評估能回報消費完成的 guest bridge，而非猜已成功後任意重送。
3. **Android KEYCODE_PASTE 是有本輪證據的替代候選**：但目前是 adb transport，不能把 279
   當 Evdev keyCode 直接塞回 gRPC。是否加入 runtime adb 依賴與等速下的行為，仍需設計決定。
   原生長按選單退路目前未驗成，不能當成可用性承諾。
4. **貼上逾時不自動重送的規則保持不變**。未知結果保留文字與狀態，由使用者確認後決定，
   不因 clipboard 相符就清掉草稿，也不補貼一次以求「看起來有字」。
5. 7.1 的「單次通道＋連續提交」已有資料；位置／選取仍缺證據。**不能把本題完成寫成
   Mac 中文輸入法問題已修好，也不能把 7.1 所有細項標成全綠。**

## 7. 原始證據與重算

[measurements/text-channels-20260911/](measurements/text-channels-20260911/README.md)
包含四份 cases.jsonl（總計 72 案）、欄位裁切圖、碼位比對、RPC／clipboard 前置紀錄、
版本與 IME、清理結果、探針版本差異及 SHA-256。受阻的選單案沒有冒填 actual_text。

- 單次矩陣：普通 EditText／LINE 各 24 案，各 12 通過、6 不符、6 受阻。
- burst：各 12 案，各 11 通過、1 不符。
- 合計：**46 通過、14 不符、12 受阻**；未執行的位置案不納入分母。

從 repo root 離線核對，不啟動模擬器、不注入文字：

```sh
python3 -B app/scripts/lib/text_channel_summarize.py app/measurements/text-channels-20260911
```

離線核對會檢查每案獨立空欄／焦點、期望與實際碼位、PASS 與欄位內容一致，再產出 summary；
不以 clipboard_readback 為成功條件。實跑用的診斷程式是 `app/scripts/lib/text_channel_probe.py`，
不是 Mirage 產品 UI 的新實作。
