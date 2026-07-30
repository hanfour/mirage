#!/usr/bin/env bash
# app/scripts/verify_reconnect.sh
# 驗收 2：殺掉模擬器後重啟，App 10 秒內自動恢復畫面。
# 前置：模擬器執行中、App 未執行。輸出 PASS/FAIL 與時間線。
set -euo pipefail
cd "$(dirname "$0")/../.."
LOG=/tmp/mirage_reconnect_test.log
ANIMATE_LOG=/tmp/mirage_reconnect_animate.log
BOOT_LOG=/tmp/mirage_reboot.log
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
# D9：**必須指定目標裝置**。沒有它，`"$ADB" shell getprop`（line ~79 的開機等待迴圈）
# 會打到「唯一連著的裝置」——而開發機上常常插著實體手機，於是這支腳本會去輪詢那支手機
# 的 `sys.boot_completed`（它永遠是 1），把「模擬器已開機」判定成立，整個重連驗收因此
# 建立在錯誤的前提上，而且不會有任何錯誤訊息。設成環境變數而非逐處補 `-s`，
# 是為了讓**之後新增的** adb 呼叫也自動涵蓋，不必記得補。
export ANDROID_SERIAL="${ANDROID_SERIAL:-emulator-5554}"

ts() { date '+%H:%M:%S'; }

# ADAPTATION（環境實測，見 task-7-report.md「screen-lock 環境阻塞」節）：
# brief 原設計的恢復判定訊號是 stdout 的 `[app] fps=` 行，但那一行只在
# Renderer.upload() 被真正呼叫時才印出，而 Renderer.upload() 只在 MTKView
# 收到實際 vsync-driven draw call 時才執行——這需要視窗被 WindowServer 真正
# 顯示合成。本機在無人操作、螢幕鎖定（Touch ID/密碼鎖）狀態下，
# WindowServer 不會把畫面合成到實體顯示器，MTKView 的內建 CVDisplayLink
# 因而完全不觸發（以 `sample` 對 App 行程取樣 3 秒證實：主執行緒僅停在
# NSApplication 事件迴圈等待，沒有任何 MTKView/CVDisplayLink 執行緒；
# `screencapture` 對桌面截圖為鎖定畫面；`lsappinfo` 顯示行程本身能建立
# gRPC 連線並收資料）。這與本任務要驗證的重連邏輯無關，純屬「測試訊號選錯
# 層」的問題：用「螢幕是否被實際看到」當作「重連是否成功」的代理指標，在
# 無人值守環境下必然恆偽。
#
# 改為在行程外部用 `nettop` 讀該 PID 的累計 bytes_in（TCP 層級，不經過
# AppKit/Metal，鎖屏也照常統計）作為主要恢復判定：bytes_in 持續成長代表
# gRPC 串流正在收幀，這才是「重連是否真的復原」的忠實訊號。`fps=` 計數
# 保留為次要／附加證據（螢幕未鎖時可額外佐證，不影響主判定）。
get_bytes_in() {
  local pid="$1" val
  val=$(nettop -p "$pid" -x -l 1 -J bytes_in 2>/dev/null \
    | awk -v p="MirageApp.$pid" '$0 ~ p {print $NF; exit}')
  echo "${val:-0}"
}

MIRAGE_FPS_LOG=1 ./app/.build/release/MirageApp > "$LOG" 2>&1 &
APP_PID=$!
sleep 8
echo "[test $(ts)] baseline: $(grep -c 'fps=' "$LOG" || true) fps lines"

echo "[test $(ts)] killing emulator..."
pkill -f qemu-system || true
sleep 3

# ADAPTATION（環境實測，見 task-7-report.md「timeline analysis」）：
# 對已運行較久的 qemu 程序做 pkill 之後，第一次立即重開有機率撞見
#   FATAL | A snapshot operation for 'mirage-poc' is pending and timeout has
#   expired. Exiting...
# ——這是 quick-boot 快照存檔被強殺中斷留下的殘留鎖，與本任務的重連邏輯無關，
# 純屬 headless emulator 環境的既有毛病。brief 原腳本用一次性
# `03_wait_boot.sh`（內部 `adb wait-for-device` 無逾時），若撞上此情況會直接
# 卡死整支腳本。改為腳本自帶「有界輪詢＋失敗重開一次」，僅在本腳本內處理模擬器
# 生命週期，不改動 phase0/scripts/02_boot_headless.sh 或 03_wait_boot.sh 本身。
boot_and_wait() {
  local attempt=1
  local max_attempts=3
  local per_attempt_timeout=90
  while [ "$attempt" -le "$max_attempts" ]; do
    if [ "$attempt" -gt 1 ]; then
      # 上一次嘗試失敗或逾時：先確保乾淨後再重開，避免與殘留程序搶 AVD 鎖。
      pkill -f qemu-system || true
      sleep 3
    fi
    echo "[test $(ts)] rebooting emulator (attempt ${attempt})..."
    phase0/scripts/02_boot_headless.sh > "$BOOT_LOG" 2>&1 &
    local boot_pid=$!
    local waited=0
    while [ "$waited" -lt "$per_attempt_timeout" ]; do
      if ! kill -0 "$boot_pid" 2>/dev/null; then
        echo "[test $(ts)] boot process exited early after ${waited}s (attempt ${attempt}); see $BOOT_LOG tail:"
        tail -5 "$BOOT_LOG"
        break
      fi
      if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
        echo "[test $(ts)] BOOTED (attempt ${attempt}, ${waited}s)"
        return 0
      fi
      sleep 1
      waited=$((waited + 1))
    done
    attempt=$((attempt + 1))
  done
  echo "[test $(ts)] FAIL: emulator did not reboot within ${max_attempts} attempts"
  kill "$APP_PID" 2>/dev/null || true
  exit 1
}

boot_and_wait
BOOT_DONE=$(date +%s)

# ADAPTATION（brief Step 2 註：streamScreenshot 為 change-driven，靜止畫面不出
# 幀。原腳本假設「終端 B」手動另開 animate.py，但那樣兩份 log 的時間軸對不齊，
# 也無法讓本腳本自行重複執行兩次驗證可重複性。改為 BOOTED 後由本腳本自己在背景
# 啟動 animate.py 90 秒，直接對齊 BOOT_DONE → 新 fps 行出現的秒數，語意與驗收
# 「模擬器重啟後 10 秒內」一致。）
# animate.py 內部 `sys.path.insert(0, "gen")` 是相對於 cwd 的相對路徑，
# 必須在 phase0/harness 目錄下執行；用子殼層 cd，不影響本腳本自身的 cwd。
(cd phase0/harness && exec "./.venv/bin/python" animate.py --seconds 90) > "$ANIMATE_LOG" 2>&1 &
ANIMATE_PID=$!
echo "[test $(ts)] animate.py started (pid ${ANIMATE_PID})"

# 開機完成後量測 10 秒內是否恢復出幀
BEFORE=$(grep -c 'fps=' "$LOG" || true)
BEFORE_BYTES=$(get_bytes_in "$APP_PID")
echo "[test $(ts)] before-recovery baseline: bytes_in=${BEFORE_BYTES} fps_lines=${BEFORE}"
RECOVERED=""
for i in $(seq 1 10); do
  sleep 1
  NOW=$(grep -c 'fps=' "$LOG" || true)
  NOW_BYTES=$(get_bytes_in "$APP_PID")
  echo "[test $(ts)] +${i}s: bytes_in=${NOW_BYTES} fps_lines=${NOW}"
  # 下限門檻：排除 keepalive/SETTINGS 噪音（一幀 540p≈2.6MB）
  if [ "$((NOW_BYTES - BEFORE_BYTES))" -ge 1000000 ]; then
    RECOVERED=$(( $(date +%s) - BOOT_DONE ))
    break
  fi
done

kill "$APP_PID" 2>/dev/null || true
kill "$ANIMATE_PID" 2>/dev/null || true
wait "$ANIMATE_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true

if [ -n "$RECOVERED" ]; then
  echo "[test $(ts)] PASS: 開機完成後 ${RECOVERED}s 恢復出幀"
else
  echo "[test $(ts)] FAIL: 10 秒內未恢復"
  echo "[test] --- app log tail (last 40 lines) ---"
  tail -40 "$LOG"
  echo "[test] --- animate log tail (last 20 lines) ---"
  tail -20 "$ANIMATE_LOG" || true
  exit 1
fi
