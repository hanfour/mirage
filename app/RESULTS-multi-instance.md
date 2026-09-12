# 多開可行性量測（2026-09-11）

問題：這台開發機能不能同時跑兩台模擬器、兩個 Mirage 視窗，各自維持可玩的 fps？
結論先講：**模擬器端撐得住，加上 Mirage 串流與畫面變化後撐不住**。在寫任何多開程式碼之前，
要先解決「兩台 × 4 vCPU」在 4 顆效能核上的競爭。

## 環境

- Apple M1，4 效能核＋4 節能核，16GB RAM；Swift 6.2.3；emulator 37.1.11.0
- AVD `mirage-game`：`hw.cpu.ncore = 4`、`hw.ramSize = 4096`、1080×2400
- 兩台都用 `-read-only -no-snapshot -grpc-use-token` 啟動（5554／8554、5556／8556），各自開著 emulator 自己的視窗
- 遊戲：Pixel Flow（`com.loomgames.pixelflow`）
- Mirage：main `9754e6d` 打包的 debug `.app`，`open -n --env MIRAGE_PORT=… --env MIRAGE_FPS_LOG=1`
- guest fps 用 `lib/guest_fps.sh`（SurfaceFlinger timestats，totalFrames ÷ displayOnTime），每組同一個約 20 秒窗口
- 「外來 CPU」＝窗口內每 5 秒一次 `top` 取樣，非 qemu 行程 CPU 合計（含 Mirage、adb、WindowServer）

## 結果

| 組 | 條件 | 5554 guest fps | 5556 guest fps | Mirage fps | 外來 CPU % |
|---|---|---|---|---|---|
| C1／C2 | 單台，選關畫面 | 59.88／59.92 | 關閉 | 無 | 86–195 |
| A1／A2 | 兩台開機，只有 5554 跑遊戲（選關畫面） | 59.51／59.29 | 桌面 | 無 | 95–239 |
| B1／B2 | 兩台都跑遊戲（選關畫面） | 59.74／59.58 | 59.72／59.73 | 無 | 91–167 |
| D1／D2 | 兩台都在關卡內（Level 5） | 59.64／59.59 | 59.35／59.72 | 無 | 92–170 |
| F1／F2 | 兩台都跑遊戲＋疊層＋持續滑動，無 Mirage | 50.04／53.32 | 48.59／51.13 | 無 | 141–246 |
| G1（單跑） | 同 F，加一個 Mirage 連 5554 | 19.74 | 19.81 | 每秒固定 3 | 280–290 |
| E1／E2 | 同 F，加兩個 Mirage 各連一台 | 13.05／14.19 | 14.03／13.50 | 兩個都每秒固定 2 | 325–366 |
| 對照 | 單台＋一個 Mirage，`verify_game_fps.sh`（注入動畫） | — | — | 平均 56.8／53.6 | — |

每組 dropped frames 都是 0。兩台都在關卡內時，qemu 各約 141–178% CPU；選關畫面約 111%。

## 讀法

1. **模擬器端可以雙開**：兩台都在關卡內，guest fps 59.35–59.72，比單台的 59.9 只少 0.2–0.5。
2. **加上 Mirage 之後兩台一起崩**：G1 只把 Mirage 接在 5554，但沒接 Mirage 的 5556 也從約 50 掉到 19.8，
   代表不是單一串流的回壓，而是整台主機的 CPU 不夠。對照組證明單台＋Mirage 仍有 54–57，所以不是今天 D73 的 token 改動造成的退化。
3. **推測的原因（未驗證）**：兩台各 4 vCPU，合計 8 個 vCPU 要搶 4 顆效能核，再加上 Mirage 每個約 65%、
   emulator 自己的視窗、WindowServer。下一步可以驗的方向：每台降到 2 vCPU、emulator 加 `-no-window`，各自單變數比較。

## 限制

- 畫面變化來源是 adb 持續滑動＋`pointer_location` 疊層，它本身就讓 guest 從約 59.7 掉到 48–53（F 組），是人造負載，不代表真實遊玩。
  但 G／E 組相對 F 組的下降（約 50 → 13–20）是在同一個注入條件下比較的。
- G 組只跑一次（其他組各兩次）。
- `-read-only` 模式下 guest 內的寫入不保存。實際的多開功能需要每台各自一個 AVD；
  `mirage-game` 的 userdata 目前 6.9GB，這才是多開的磁碟成本。執行中的模擬器本身幾乎不佔額外磁碟
  （單台開機到遊戲中差 1 MiB 以內、兩台 read-only 合計 222 MiB），記憶檔裡「執行期佔 14GB」在目前的啟動旗標下不成立。
- 同一個 AVD 開第二台時，若第一台沒有 `-read-only`，第二台會直接失敗：
  `Another emulator instance is running. Please close it or run all emulators with -read-only flag.`
- `emu.sh` 目前不支援多開：`running()` 會匹配任何 qemu 行程，而且 serial 是固定的。

## 2026-09-12 追加：vCPU 與視窗兩個變數

問題：把每台 vCPU 從 4 降到 2、或用 `-no-window`，能不能讓「兩台＋Mirage」撐住？由 subagent 執行，每組兩台都在關卡內（像素簽名確認）、疊層＋持續滑動、一個 Mirage 連 8554，各量兩輪。

| 組合 | 5554 guest fps | 5556 guest fps | Mirage fps 中位數 | 外來 CPU % | qemu CPU %（5554／5556） |
|---|---|---|---|---|---|
| 4 vCPU、有視窗（昨天 G 的重跑） | 9.99／9.75 | 8.44／10.16 | 3／3 | 275–326 | 81–184／79–174 |
| 2 vCPU、有視窗 | 解析失敗×2 | 解析失敗×2 | 2／2 | 247–319 | 43–132／38–130 |
| 4 vCPU、`-no-window` | 0.48／1.32 | 1.23／0.07 | 1／2 | 304–376 | 60–157／52–146 |
| 2 vCPU、`-no-window` | 0.54／0.54 | 3.54／1.60 | 2／1 | 357–430 | 53–153／46–153 |
| 單台、2 vCPU、有視窗＋Mirage | 20.31／21.72 | 關閉 | 3／3 | 230–287 | 135–212 |
| 單台、4 vCPU、`-no-window`、無滑動、無 Mirage | 選關 32.23、關卡內 29.30 | 關閉 | 無 | 141–278 | 146–339 |

讀法：
- 降 vCPU 讓單台就撐不住（20 對比昨天單台 4 vCPU＋Mirage 的 54–57），兩台則直接 ANR（`Process system isn't responding`），timestats 裡沒有遊戲 layer 的幀。
- `-no-window` 比有視窗更慢：單台無負載時 29–32 對比有視窗的 59.7，兩台時掉到 1 fps 以下，進關卡要 5 到 10 分鐘。emulator log 兩者都是 Apple M1 Metal translator，差異不在渲染後端，原因未查。
- 昨天 G 組的 19.74／19.81 存疑：今天用「固定等 40＋15 秒」的舊流程重跑，量到 19.74／19.55 的那輪截圖顯示 5554 在 Loading、5556 在選關畫面，不在關卡內。用像素簽名確認在關卡內之後只有約 10。
- 這台機器沒有 Mirage 時的外來 CPU 基線就有 140–280%（WindowServer、iTerm2、開發工具），量測全程都在這個底噪上。

結論：在這台 M1 上「兩台同時可玩」不成立，兩個可調的變數都讓它更糟。多開要做，只能做「多台各自存在、同一時間只有一台接 Mirage」。

限制：量測窗口因 `dumpsys` 在負載下極慢而變成 23–50 秒（fps 是除以實際 displayOnTime，不受影響）；每組間有 ANR 對話框被按掉；量測腳本與每組原始輸出在 session scratchpad，未進 repo。
