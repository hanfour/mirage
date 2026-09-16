# 語音轉文字設計

讓 guest 播放的語音（LINE 語音訊息為主要情境）即時轉成文字，顯示在 Mac 視窗上。

## 1. 已確認的事實

以下都在 2026-09-16 於本機實測，不是推論。

- macOS 26.6.2，`SFSpeechRecognizer` 支援 63 個語系，`zh-TW` 可用且
  **裝置端辨識為 true**（`zh-CN` 為 false，只能走雲端，因此不採用）。
- Mirage 的音訊扇出結構已存在：`AudioSink` 協定加 `BroadcastAudioSink`，
  目前 primary 是 `AudioRingBuffer`、secondary 是手機遙控的 `RemoteAudioForwarder`。
- 靜音是在 `AVAudioEngine.mainMixerNode.outputVolume` 做的，環形緩衝與各 sink
  照樣收得到樣本，所以「靜音但仍轉文字」不需要額外設計。
- 來源格式固定 48000Hz 立體聲 Float32（`AudioStreamFormat.standard`）。
  LINE 語音訊息在 guest 內是 16000Hz 單聲道，經 emulator 重採樣後才送出。

## 2. 不做的事

- **不播放就轉文字**：emulator 只在 guest 實際播放時產生音訊，不播就沒有訊號。
  唯一繞法是讀 LINE 在 guest 內的快取檔，需要 root、動到私人訊息儲存區、
  且隨 LINE 改版而壞。不做。
- **加速辨識**：音訊是即時串流，30 秒的語音就是要 30 秒。
- **雲端辨識**：語音是私人內容，一律裝置端，`requiresOnDeviceRecognition = true`。
- **Whisper 或其他本機模型**：第一版不做。介面留得住，之後要換再說。
- **辨識結果存檔或索引**：只留最後一則在記憶體，不寫入磁碟。

## 3. 架構

```
emulator → EmulatorClient → BroadcastAudioSink
                              ├─ primary:   AudioRingBuffer → AudioPlayer → 喇叭
                              └─ secondary: 由 AppModel 依目前開啟的功能組合
                                            ├─ RemoteAudioForwarder（手機遙控）
                                            └─ SpeechTranscriberSink（本設計）
```

`BroadcastAudioSink` 目前只有一個 secondary。同時開啟手機遙控與語音轉文字時要兩個，
因此新增 `FanOutAudioSink`（多個下游、逐一轉送、任一下游丟例外不影響其他）取代
`BroadcastAudioSink` 的 secondary 欄位只能放一個的限制。primary 仍然分開，
理由與既有相同：本機播放不可以被任何下游拖慢。

### MirageCore（純函式，逐行單元測試）

- `SpeechAudioConverter`：48000Hz 立體聲 Float32 → 16000Hz 單聲道 Float32。
  降取樣用整數倍抽取（48000 / 16000 = 3），先把左右聲道平均成單聲道再每三個取一個。
  **不做抗鋸齒濾波**：語音頻帶遠低於 8kHz，而來源本身就是 16kHz 單聲道升上來的，
  高頻沒有內容可混疊。這個假設寫在這裡，之後若改用真實 48kHz 音源要重新檢視。
- `SpeechSegmenter`：依「有沒有音訊封包」決定一段語音的起訖。
  收到第一個非空封包為開始；連續 `silenceWindow`（預設 1.0 秒）沒有封包為結束。
  純狀態機，輸入是「這一秒有幾個封包」與時間，輸出是 `.began`／`.continued`／`.ended`。
  用封包數而不是音量：guest 停止輸出時 emulator 送零個封包，這個訊號既有的
  `AudioSupplyMonitor` 已經在用，判準一致。

### MirageShell（系統框架，活體驗證）

- `SpeechTranscriberSink`：`AudioSink`，把轉換後的樣本餵給
  `SFSpeechAudioBufferRecognitionRequest`。一段語音一個 `SFSpeechRecognitionTask`。
  段落結束時 `endAudio()`，拿最終結果後結束任務。
- 授權：首次啟用時 `SFSpeechRecognizer.requestAuthorization`。未授權或
  `zh-TW` 不可用時**降級為不轉文字**，不影響音訊與畫面（與 `AudioPlayer` 啟動失敗
  的處理一致）。
- `SpeechOverlay`：Mirage 視窗底部的字幕浮層。播放中逐句更新（
  `SFSpeechRecognitionResult.isFinal == false` 的部分結果），段落結束後保留最後一則。
  點一下複製到剪貼簿。選單列提供開關，預設關閉（要授權才能用，不該未經同意就要權限）。

## 4. 錯誤處理

| 情況 | 行為 |
|---|---|
| 使用者拒絕授權 | 選單列那一項顯示原因，功能保持關閉，不重複要求 |
| `zh-TW` 不可用或裝置端模型未下載 | 同上，顯示「這台機器沒有可用的裝置端中文辨識」 |
| 辨識任務出錯 | 結束該段、記錄一行 log、下一段重新開始，不停用整個功能 |
| 音訊崩潰（D44） | 不特別處理。那段音訊本身殘缺，辨識結果會爛，這是已知且已記載的缺陷 |
| 一段語音超過 60 秒 | 強制切段並開新任務。`SFSpeechRecognitionTask` 有長度上限，不切會整段丟失 |

## 5. 驗證

- `SpeechAudioConverter`：用已知輸入驗算術。1kHz 正弦波降取樣後的峰值與長度、
  左右聲道不同值時的平均、樣本數不是 3 的倍數時的尾端處理。
- `SpeechSegmenter`：開始、持續、結束、靜音窗口邊界兩側、超過 60 秒強制切段。
- 活體：用受控音源做不了（正弦波沒有語意）。改用 `say` 產生的已知語句
  （例如「今天天氣很好」）寫成 WAV，由 guest 的 Chrome 播放，斷言辨識結果與原句
  的字元重疊率高於門檻。門檻先探測再定，不先猜一個數字。

## 6. 分階段交付

1. `FanOutAudioSink` 與既有兩個 sink 的接線（不含辨識）。
2. `SpeechAudioConverter` 與 `SpeechSegmenter` 純函式與測試。
3. `SpeechTranscriberSink` 與授權流程，辨識結果先只印 log。
4. `SpeechOverlay` 與選單列開關。
5. 活體驗證腳本與門檻探測。
