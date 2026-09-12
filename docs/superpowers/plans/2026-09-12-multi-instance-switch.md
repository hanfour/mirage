# 模擬器多開切換（選項 B）實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓多台模擬器各自存在、各自開機，Mirage 同一時間只接其中一台，並能從選單列切換到另一台。

**Architecture:** 三層各加一個純函式層與一個 I/O 接點：`emu.sh` 把「名稱 → 三元組」與「從 pgrep 輸出判斷誰在跑」抽進 `lib/emu_instances.sh`（自我測試餵假輸出）；`EmulatorDiscovery` 沿用既有的 `pid_*.ini` 讀檔與注入方式加一個「列出全部」；`EmulatorClient` 加 `setEndpoint`，`AppModel` 的切換就是 `stop → setEndpoint → start`，選單列子選單的內容由純函式 `InstanceMenu.entries` 決定。

**Tech Stack:** bash（`set -uo pipefail`）、Swift 6 actor、Swift Testing、AppKit `NSMenu`、grpc-swift。

**Spec:** `docs/specs/2026-09-12-multi-instance-design.md`（已核可，範圍是 §3 選項 B）。

## Global Constraints

- 一台實例 = （AVD 名稱、console 埠、gRPC 埠）；每台各自一個 AVD，**不加 `-read-only`**；同一個 AVD 被指定兩次要直接報錯退出（spec §3.1）。
- `emu.sh` 不帶 `-n` 的 start／stop 行為一行都不能變：預設仍是 `mirage-game`／5554／8554，`MIRAGE_AVD`／`MIRAGE_PORT`／`MIRAGE_GRPC` 覆寫照舊（`app/scripts/mac/啟動模擬器.command:4` 與 `停止模擬器.command:3` 直接呼叫 `./emu.sh start`／`stop`；grep 全 `app/scripts` 沒有 verify_* 呼叫 emu.sh）。
- `running()` 改成比對該實例的 console 埠（spec §3.2）；`status` 列出所有執行中的實例與 gRPC 綁定位址；`stop` 只停指定實例。
- 同一時間只有一台接 Mirage（spec §2 選項 B）；切換期間只顯示既有 `ConnectionBanner`（spec §3.3），不做新畫面。
- `MIRAGE_HOST`／`MIRAGE_PORT` 覆寫維持現況（spec §3.3、`EmulatorClient.defaultEndpoint`）。
- 鍵位 profile 依遊戲偵測自動套用，與實例無關，不改（spec §3.3）。
- 不做：兩個 Mirage 視窗、同時串流兩台、在 Mirage UI 裡建立或刪除實例（spec §3.4）。
- Swift Testing：Bool 直接 `#expect(x)`／`#expect(!x)`，不可 `== true`／`== false`（`ci.sh` 閘門 5 會擋）；不可用 `guard … else { return }` 當 skip（閘門 3 會擋），環境條件用 `@Test(.enabled(if:))`。
- shell：變數緊接全形標點一律 `${VAR}`（閘門 4 會擋）；`source "$(dirname "$0")/…"` 必須在任何 `cd` 之前（閘門 4 第二段會擋）。
- 檔案 200 到 400 行；純函式與 I/O 分開。
- 每個 task 最後 commit，訊息用繁體中文 conventional commits，不加 attribution 行。

## 先讀的既有程式碼（型別與簽章的依據）

| 項目 | 位置 | 本計畫怎麼用 |
|---|---|---|
| `running()` 匹配任何 qemu | `app/scripts/emu.sh:26` | Task 2 換成 `emu_is_running`（比對 `-port`） |
| `grpc_bind()` 用全域 `$GRPC` | `app/scripts/emu.sh:28` | Task 2 改成吃參數，status 列全部時逐台查 |
| 自我測試的 `run_case`／`check` 形式 | `app/scripts/lib/verify_common_selftest.sh:12-28` | Task 1 的 `emu_selftest.sh` 照抄形式 |
| 閘門 7 每支自我測試的區塊 | `app/scripts/ci.sh:335-340`（verify_common 那段） | Task 1 加同形區塊；標題在 `:320`、結尾清單在 `:437` |
| 閘門 4 的 lint | `app/scripts/ci.sh:199-217` | 寫 shell 時避開 |
| `DiscoveryFile`／`parseINI`／`pid(from:)`／`selectToken` | `app/Sources/MirageCore/EmulatorDiscovery.swift:6-56` | Task 3 沿用同一組純函式與注入 |
| `discoverToken(port:directory:isAlive:readFiles:)` 的注入簽章 | `EmulatorDiscovery.swift:87-91` | Task 3 的 `listInstances` 同一組參數 |
| 真實 `pid_*.ini` 樣本 | `app/Tests/MirageCoreTests/EmulatorDiscoveryTests.swift:9-22` | Task 3 測試用同一份（含 `avd.name`／`port.serial`／`grpc.port`） |
| `EmulatorEndpoint(host:port:overrideProblem:)`、`.default`、`resolve(environment:)` | `app/Sources/MirageCore/EmulatorEndpoint.swift:19-25,34` | Task 4 的 `setEndpoint` 吃它 |
| `EmulatorClient` 的 `host`／`port` 是 `private let` | `app/Sources/MirageCore/EmulatorClient.swift:7-8` | Task 4 改成一個 `private var endpoint` |
| `init(host:port:makeTransport:…)` | `EmulatorClient.swift:82-104` | 簽章不動 |
| `start(box:width:height:)`、`setStreamSize`、`stop()` | `EmulatorClient.swift:146-178` | Task 4 在 `stop()` 加等待舊迴圈結束 |
| `runConnectionLoop()` 的 `if !running { break }` 與 `guard running else { break }` | `EmulatorClient.swift:260-288` | Task 4 說明競態的來源 |
| `ensureChannel()` 用 `GrpcChannelBox(host:port:)` | `EmulatorClient.swift:294-306` | Task 4 改讀 `endpoint.host`／`endpoint.port` |
| `MockTransport`、`SleepRecorder`、`ScriptedProbe`、`LatestFrameBox` | `app/Tests/MirageCoreTests/EmulatorClientReconnectTests.swift:6-58`、`HealthProbeTests.swift:15-25` | Task 4 測試沿用 |
| `AppModel.client`／`box`／`connState`、`start()`、`defaultStreamSize` | `app/Sources/MirageShell/AppModel.swift:13-16,116-152` | Task 6 |
| `AppModel.startLifecycle()` 建 `MenuBarController` 並綁回呼 | `AppModel.swift:445-463` | Task 6 在這裡呼叫 `setupInstanceMenu()` |
| extension 慣例（`setupFullScreen` 綁 `menuBar?.onToggleFullScreen`） | `app/Sources/MirageShell/AppModel+FullScreen.swift:8-24` | Task 6 的 `AppModel+Instances.swift` 同形 |
| `MenuBarController` 的 `muteItem`／`forceMenu`／`menuNeedsUpdate` | `app/Sources/MirageShell/Lifecycle/MenuBarController.swift:14-15,46,50-52,73-75,99-108` | Task 7 加 `instanceMenu` |
| `ConnectionBanner(state:)` 已掛在 Scene | `app/Sources/MirageShell/MirageScene.swift:61`、`ConnectionBanner.swift:4-18` | 切換期間 `.disconnected`→`.connecting` 自然顯示，不改 |
| Shell 層測試的 `tempStore`／`AppModel(store:starterBindings:)` | `app/Tests/MirageShellTests/AppModelEditingTests.swift:9-14,33` | Task 6 測試沿用 |
| `verify_keyboard.sh` 的 `MIRAGE_ADB_SERIAL`／`MIRAGE_PORT` 覆寫 | `app/scripts/verify_keyboard.sh:23-24` | Task 8 逐台呼叫 |
| `verify_common.sh` 的 `require_adb`／`assert_ok`／`assert_equals` | `app/scripts/lib/verify_common.sh:18-83` | Task 8 |

## 兩個先決定的設計

**1. 切換是「加 `setEndpoint`」，不是「建新的 `EmulatorClient`」。** 同一個 `client` 實例被五處持有：`InputQueue(injector: client)`（`AppModel.swift:35`）、`AppLifecycle(client:)`（`AppModel.swift:446`）、`MirrorView(client: model.client, …)`（`MirageScene.swift:46`）、`client.setAudioSink(audioRing)`（`AppModel+Audio.swift:22`）、`client.states`／`client.guestClipboard` 的兩個長駐消費者（`AppModel.swift:142-150,465-469`）。換實例就要五處重綁，而 `client.states` 是單一 continuation 的 `AsyncStream`，重綁消費者正是 D30 那類錯誤的形狀。相對地，`ensureChannel()`（`EmulatorClient.swift:294-306`）每次重連都用 `host`／`port` 重建 `GrpcChannelBox`，把兩個 `let` 換成一個 `private var endpoint`，`stop()` 之後改它、再 `start()`，其他一切不動。`init(host:port:…)` 簽章不變，`defaultEndpoint` 不變。

**2. `stop()` 要等舊迴圈真的結束。** 現在 `stop()` 只設 `running = false` 並 `cancel()`，不等 `loopTask`。舊迴圈若正卡在 `probe(timeout:)`（最長 1 秒），`stop()` 返回、`start()` 把 `running` 設回 `true` 之後它才醒來，`EmulatorClient.swift:266` 的 `if !running { break }` 看到的是 `true`，接著走 `:281-284` 的 `dropChannel()`——**把新迴圈剛建好的 channel 拆掉**，然後兩條迴圈同時在跑。單台時 stop 之後從來沒有立刻 start 過，所以這條路徑沒被踩到；切換會每次都踩。修法是 `stop()` 尾端 `await loopTask?.value`：迴圈在每個 await 之後都檢查 `running`，取消會讓 `sleeper` 拋出、`breakCont` 會結束 `connectedRun()`，所以等待有上界（`probeTimeout`）。

## 檔案結構

| 檔案 | 動作 | 職責 |
|---|---|---|
| `app/scripts/lib/emu_instances.sh` | 新增 | 純函式：名稱 → 三元組、表格驗證、從 pgrep 輸出列出執行中實例、判斷是否執行中、AVD 衝突 |
| `app/scripts/lib/emu_selftest.sh` | 新增 | 上面那支的自我測試，餵假輸出，不需模擬器 |
| `app/scripts/ci.sh` | 修改 `:320,:335-340` 附近、`:437` | 閘門 7 加第十支 |
| `app/scripts/emu.sh` | 修改（全檔重寫，start／stop 語意不變） | `-n`、`running()` 比對埠、`status` 列全部、AVD 衝突檢查 |
| `app/Sources/MirageCore/EmulatorInstance.swift` | 新增 | `EmulatorInstance` 值型別＋`EmulatorDiscovery.listInstances`（純函式＋注入 I/O） |
| `app/Tests/MirageCoreTests/EmulatorInstanceTests.swift` | 新增 | 用真實 ini 格式測 |
| `app/Sources/MirageCore/EmulatorClient.swift` | 修改 `:7-8,105-106,169-178,294-306` | `endpoint` 變數、`setEndpoint`、`currentEndpoint`、`isRunning`、`requestedStreamSize`、`stop()` 等迴圈 |
| `app/Tests/MirageCoreTests/EmulatorClientEndpointTests.swift` | 新增 | `setEndpoint` 在跑／沒跑的語意、stop 等迴圈 |
| `app/Sources/MirageShell/Lifecycle/InstanceMenu.swift` | 新增 | 純函式：實例清單＋目前端點 → 選單項目 |
| `app/Tests/MirageShellTests/InstanceMenuTests.swift` | 新增 | 純函式測試 |
| `app/Sources/MirageShell/AppModel.swift` | 修改 `:16` 附近加一個儲存屬性、`:461-463` 加一行 | `currentEndpoint`；`startLifecycle` 呼叫 `setupInstanceMenu()` |
| `app/Sources/MirageShell/AppModel+Instances.swift` | 新增 | `refreshInstances()`、`switchInstance(to:)`、`setupInstanceMenu()` |
| `app/Tests/MirageShellTests/AppModelInstanceTests.swift` | 新增 | 切換後端點、同端點 no-op |
| `app/Sources/MirageShell/Lifecycle/MenuBarController.swift` | 修改 | 「切換模擬器」子選單、`populate(instanceMenu:entries:)` |
| `app/Tests/MirageShellTests/MenuBarInstanceMenuTests.swift` | 新增 | `populate` 的項目、勾選、停用 |
| `app/scripts/verify_instance_switch.sh` | 新增 | 活體：兩台起、5554→5556→5554 各跑 `verify_keyboard.sh`、另一台 `sys.boot_completed` 仍為 1 |
| `app/README.md` | 修改（加一節） | 多開用法 |

---

### Task 1: `emu_instances.sh` 純函式層＋自我測試＋閘門 7

**Files:**
- Create: `app/scripts/lib/emu_instances.sh`
- Create: `app/scripts/lib/emu_selftest.sh`
- Modify: `app/scripts/ci.sh:320`（標題）、`:373-380` 之後（加區塊）、`:437`（結尾清單）

**Interfaces:**
- Consumes: 無。
- Produces（bash 函式，Task 2 與 Task 8 用）：
  - `EMU_DEFAULT_INSTANCES`：字串，`"mirage-game:5554:8554 mirage-poc:5556:8556"`。
  - `emu_resolve <name> [table]`：stdout 印 `"<avd> <console> <grpc>"`；找不到或三元組無效回 1 並在 stderr 說明。
  - `emu_table_check [table]`：AVD、console 埠、gRPC 埠任一重複或無效回 1。
  - `emu_running_instances "<pgrep -fl qemu-system 的輸出>"`：每台一行 `"<pid> <avd> <console> <grpc|?>"`，依 console 埠排序。
  - `emu_is_running "<pgrep 輸出>" <console>`：該埠有 qemu 在跑回 0。
  - `emu_avd_conflict "<pgrep 輸出>" <avd> <console>`：同名 AVD 在**別的**埠上跑時回 0 並印出那個埠。

- [ ] **Step 1: 寫自我測試（會失敗，因為函式庫還不存在）**

`app/scripts/lib/emu_selftest.sh`：

```bash
#!/usr/bin/env bash
# emu_instances.sh 的自我測試。**不需要模擬器、不需要 adb**：所有 pgrep 輸出都是假的。
#
# 假資料的來源（fixtures-must-come-from-real-logs）：
#   PS_ONE 是 2026-09-12 在開發機上 `pgrep -fl qemu-system` 的實際輸出（路徑原樣保留）。
#   PS_TWO 的第二行照 RESULTS-multi-instance.md 記載的兩台啟動旗標（含 -read-only）依同一形狀寫成。
#   PS_NOGRPC 是 emu.sh 檔頭記載的「不指定 -grpc 會拿到隨機埠」那種行程。
#
# 用法：./scripts/lib/emu_selftest.sh（退出碼 0 = 全部通過）
set -uo pipefail
LIB="$(dirname "$0")/emu_instances.sh"
FAILURES=0

run_case() {
    ( set +e; source "$LIB" > /dev/null 2>&1; eval "$1" > /dev/null 2>&1 )
    echo $?
}

run_out() {
    ( set +e; source "$LIB" > /dev/null 2>&1; eval "$1" 2>/dev/null )
}

check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "✅ $desc"
    else
        echo "❌ ${desc}：得到 '${got}'，期待 '${want}'"
        FAILURES=$((FAILURES + 1))
    fi
}

QEMU='/Users/hanfourhuang/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64'
PS_ONE="62234 ${QEMU} -avd mirage-game -no-snapshot -port 5554 -grpc 8554 -grpc-use-token"
PS_TWO="${PS_ONE}
62911 ${QEMU} -avd mirage-poc -read-only -no-snapshot -port 5556 -grpc 8556 -grpc-use-token"
PS_NOGRPC="70001 ${QEMU} -avd mirage-game -no-snapshot -port 5554"
# 倒序：status 的輸出要依埠排序，不能依 pgrep 的順序。
PS_REVERSED="62911 ${QEMU} -avd mirage-poc -no-snapshot -port 5556 -grpc 8556 -grpc-use-token
${PS_ONE}"

echo "=== emu_instances.sh 自我測試 ==="

echo "--- emu_resolve ---"
check "預設名稱 → 現在的三元組" \
      "$(run_out 'emu_resolve mirage-game')" "mirage-game 5554 8554"
check "第二台 → 5556／8556" \
      "$(run_out 'emu_resolve mirage-poc')" "mirage-poc 5556 8556"
check "未知名稱 → 1" "$(run_case 'emu_resolve nope')" 1
check "未知名稱 → 不印任何三元組" "$(run_out 'emu_resolve nope')" ""
check "自訂表格可覆寫" \
      "$(run_out 'emu_resolve alt "alt:5558:8558"')" "alt 5558 8558"
check "console 埠是奇數 → 1（emulator 只接受偶數埠）" \
      "$(run_case 'emu_resolve bad "bad:5555:8555"')" 1
check "console 埠超出 5554–5682 → 1" \
      "$(run_case 'emu_resolve bad "bad:5000:8000"')" 1
check "gRPC 埠不是數字 → 1" \
      "$(run_case 'emu_resolve bad "bad:5554:x"')" 1
check "少一欄 → 1" "$(run_case 'emu_resolve bad "bad:5554"')" 1

echo "--- emu_table_check ---"
check "預設表格通過" "$(run_case 'emu_table_check')" 0
check "同一個 AVD 出現兩次 → 1" \
      "$(run_case 'emu_table_check "a:5554:8554 a:5556:8556"')" 1
check "同一個 console 埠出現兩次 → 1" \
      "$(run_case 'emu_table_check "a:5554:8554 b:5554:8556"')" 1
check "同一個 gRPC 埠出現兩次 → 1" \
      "$(run_case 'emu_table_check "a:5554:8554 b:5556:8554"')" 1
check "表格裡有無效三元組 → 1" \
      "$(run_case 'emu_table_check "a:5554:8554 b:5557:8556"')" 1

echo "--- emu_running_instances ---"
check "一台 → 一行 pid avd console grpc" \
      "$(run_out "emu_running_instances '${PS_ONE}'")" "62234 mirage-game 5554 8554"
check "兩台 → 兩行" \
      "$(run_out "emu_running_instances '${PS_TWO}'")" \
      "62234 mirage-game 5554 8554
62911 mirage-poc 5556 8556"
check "倒序輸入 → 仍依 console 埠排序" \
      "$(run_out "emu_running_instances '${PS_REVERSED}'")" \
      "62234 mirage-game 5554 8554
62911 mirage-poc 5556 8556"
check "沒有 -grpc → grpc 欄印 ?" \
      "$(run_out "emu_running_instances '${PS_NOGRPC}'")" "70001 mirage-game 5554 ?"
check "空輸入 → 空" "$(run_out "emu_running_instances ''")" ""
check "不含 qemu-system 的行被忽略" \
      "$(run_out "emu_running_instances '123 /bin/bash ./emu.sh -n mirage-poc start -port 5556'")" ""

echo "--- emu_is_running ---"
check "一台在 5554，問 5554 → 0" "$(run_case "emu_is_running '${PS_ONE}' 5554")" 0
# 這一條是整組的核心：舊的 running() 匹配任何 qemu，第二台會被當成「已在執行」。
check "一台在 5554，問 5556 → 1" "$(run_case "emu_is_running '${PS_ONE}' 5556")" 1
check "兩台，問 5556 → 0" "$(run_case "emu_is_running '${PS_TWO}' 5556")" 0
check "兩台，問 5558 → 1" "$(run_case "emu_is_running '${PS_TWO}' 5558")" 1
check "埠要整段相等，555 不能匹配 5554" "$(run_case "emu_is_running '${PS_ONE}' 555")" 1
check "空輸入 → 1" "$(run_case "emu_is_running '' 5554")" 1

echo "--- emu_avd_conflict ---"
check "mirage-game 在 5554 跑，要在 5556 再開 → 衝突（0）" \
      "$(run_case "emu_avd_conflict '${PS_ONE}' mirage-game 5556")" 0
check "衝突時印出佔用的埠" \
      "$(run_out "emu_avd_conflict '${PS_ONE}' mirage-game 5556")" "5554"
check "同一個 AVD 同一個埠 → 不算衝突（1），那是「已在執行」" \
      "$(run_case "emu_avd_conflict '${PS_ONE}' mirage-game 5554")" 1
check "不同 AVD → 1" "$(run_case "emu_avd_conflict '${PS_ONE}' mirage-poc 5556")" 1
check "沒有任何 qemu → 1" "$(run_case "emu_avd_conflict '' mirage-game 5554")" 1

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "$FAILURES 項失敗"
exit 1
```

- [ ] **Step 2: 跑自我測試，確認它紅**

Run: `chmod +x app/scripts/lib/emu_selftest.sh && app/scripts/lib/emu_selftest.sh; echo "rc=$?"`
Expected: 每條都 ❌（`source` 失敗、函式不存在，`run_case` 得到 127 或 1），最後 `rc=1`。

- [ ] **Step 3: 寫函式庫**

`app/scripts/lib/emu_instances.sh`：

```bash
#!/usr/bin/env bash
# emu.sh 的純函式層。用法：source "$(dirname "$0")/lib/emu_instances.sh"
#
# **這裡沒有任何 I/O**：不呼叫 pgrep、lsof、adb。emu.sh 把真實的 `pgrep -fl qemu-system`
# 輸出餵進來，emu_selftest.sh 餵假的。理由與 verify_common.sh 相同——判斷只有一份，
# 注入故障驗一次就夠。
#
# 一台實例由三個值決定：AVD 名稱、console 埠（5554、5556、……偶數）、gRPC 埠。
# 實例名稱就是 AVD 名稱：規格 §3.1 要求每台各自一個 AVD，所以名稱與 AVD 一對一，
# 不需要第四個識別字。

# 預設實例表。格式：空白分隔的項目，每項 `名稱:console埠:gRPC埠`。
# 第一項就是不帶 -n 時的預設（mirage-game／5554／8554，與 emu.sh 的 MIRAGE_* 預設值相同）。
# 第二項用 tools/provision 已宣告的另一台 AVD（tools/provision/lib/avdspec.py 只有這兩台）。
# 埠號沿用 tools/probe/lib/targets.py 的 5556／8556 慣例。
# 可用環境變數 MIRAGE_INSTANCES 整份覆寫（emu.sh 負責讀它，這裡只吃參數）。
EMU_DEFAULT_INSTANCES="mirage-game:5554:8554 mirage-poc:5556:8556"

# 三元組驗證。console 埠必須是 5554–5682 的偶數（emulator -port 的限制，奇數是 adb 埠）。
emu_validate_triplet() {
    local avd="$1" port="$2" grpc="$3"
    if [ -z "$avd" ]; then
        echo "❌ 實例表項目缺 AVD 名稱" >&2; return 1
    fi
    case "$port" in
        ''|*[!0-9]*) echo "❌ ${avd}：console 埠 '${port}' 不是整數" >&2; return 1 ;;
    esac
    if [ "$port" -lt 5554 ] || [ "$port" -gt 5682 ] || [ $((port % 2)) -ne 0 ]; then
        echo "❌ ${avd}：console 埠 ${port} 必須是 5554–5682 的偶數" >&2; return 1
    fi
    case "$grpc" in
        ''|*[!0-9]*) echo "❌ ${avd}：gRPC 埠 '${grpc}' 不是整數" >&2; return 1 ;;
    esac
    if [ "$grpc" -lt 1 ] || [ "$grpc" -gt 65535 ]; then
        echo "❌ ${avd}：gRPC 埠 ${grpc} 不在 1–65535" >&2; return 1
    fi
    return 0
}

# emu_resolve <名稱> [實例表] → stdout "avd console grpc"；找不到回 1。
emu_resolve() {
    local name="$1" table="${2:-$EMU_DEFAULT_INSTANCES}" entry avd port grpc
    for entry in $table; do
        IFS=: read -r avd port grpc <<< "$entry"
        [ "$avd" = "$name" ] || continue
        emu_validate_triplet "$avd" "${port:-}" "${grpc:-}" || return 1
        printf '%s %s %s\n' "$avd" "$port" "$grpc"
        return 0
    done
    echo "❌ 未知的實例名稱：${name}。可用：$(emu_names "$table")" >&2
    return 1
}

# 列出表格裡的名稱（給錯誤訊息用）。
emu_names() {
    local entry names=""
    for entry in $1; do
        names="${names}${names:+, }${entry%%:*}"
    done
    printf '%s\n' "$names"
}

# emu_table_check [實例表] → AVD／console 埠／gRPC 埠任一重複，或任一三元組無效，回 1。
emu_table_check() {
    local table="${1:-$EMU_DEFAULT_INSTANCES}" entry avd port grpc
    local avds="" ports="" grpcs=""
    for entry in $table; do
        IFS=: read -r avd port grpc <<< "$entry"
        emu_validate_triplet "${avd:-}" "${port:-}" "${grpc:-}" || return 1
        case " $avds " in *" $avd "*) echo "❌ 實例表裡 AVD ${avd} 出現兩次；每台要各自一個 AVD" >&2; return 1 ;; esac
        case " $ports " in *" $port "*) echo "❌ 實例表裡 console 埠 ${port} 出現兩次" >&2; return 1 ;; esac
        case " $grpcs " in *" $grpc "*) echo "❌ 實例表裡 gRPC 埠 ${grpc} 出現兩次" >&2; return 1 ;; esac
        avds="$avds $avd"; ports="$ports $port"; grpcs="$grpcs $grpc"
    done
    return 0
}

# emu_running_instances "<pgrep -fl qemu-system 的輸出>" → 每台一行 "pid avd console grpc"，
# 依 console 埠排序；沒帶 -grpc 的行程 grpc 欄印 `?`（那是隨機埠，Mirage 連不上）。
# 只認含 qemu-system 且有 -port 的行——pgrep -f 比對的是整條命令列，別的行程也可能提到埠號。
emu_running_instances() {
    printf '%s\n' "$1" | awk '
        /qemu-system/ {
            pid = $1; avd = "?"; port = ""; grpc = "?"
            for (i = 2; i <= NF; i++) {
                if ($i == "-avd")  avd  = $(i + 1)
                if ($i == "-port") port = $(i + 1)
                if ($i == "-grpc") grpc = $(i + 1)
            }
            if (port != "") print pid, avd, port, grpc
        }' | sort -k3,3n
}

# emu_is_running "<pgrep 輸出>" <console 埠> → 該埠有 qemu 在跑回 0。
# 比對整個欄位，不是子字串：555 不會匹配 5554。
emu_is_running() {
    emu_running_instances "$1" | awk -v p="$2" '$3 == p { found = 1 } END { exit !found }'
}

# emu_avd_conflict "<pgrep 輸出>" <avd> <console 埠> → 同名 AVD 在別的埠上跑時回 0 並印那個埠。
# 同一個埠不算衝突（那是「已在執行」，由 emu_is_running 處理）。
emu_avd_conflict() {
    emu_running_instances "$1" | awk -v a="$2" -v p="$3" '
        $2 == a && $3 != p { print $3; found = 1 }
        END { exit !found }'
}
```

- [ ] **Step 4: 跑自我測試，確認全綠**

Run: `app/scripts/lib/emu_selftest.sh; echo "rc=$?"`
Expected: 全部 ✅、`全部通過`、`rc=0`。

- [ ] **Step 5: 突變檢查（自我測試要能紅）**

把 `emu_is_running` 裡的 `$3 == p` 暫時改成 `$3 ~ p`，重跑：`「埠要整段相等，555 不能匹配 5554」` 必須變 ❌。改回來，再跑一次確認綠。

- [ ] **Step 6: 加進 `ci.sh` 閘門 7**

`app/scripts/ci.sh:320` 的標題改成：

```bash
echo "=== 閘門 7：十支共用函式庫的自我測試 ==="
```

在 `backpressure_selftest.sh` 那段（`:382-389`）之後、`echo ""`（`:391`）之前插入：

```bash
# emu_selftest.sh 是第十支自我測試（2026-09-12，模擬器多開）。emu_instances.sh 決定 emu.sh
# 認不認得「哪台在跑」——判錯的後果是靜默的：第二台被當成第一台「已在執行」而不啟動、
# 或 stop 殺錯台。純函式不需要模擬器，直接納入閘門 7。
if ./scripts/lib/emu_selftest.sh > /dev/null 2>&1; then
    ok "emu_instances.sh 自我測試通過"
else
    fail "emu_instances.sh 自我測試失敗（重跑 ./scripts/lib/emu_selftest.sh 看細節）："
    ./scripts/lib/emu_selftest.sh 2>&1 | grep "❌" | sed 's/^/   /'
fi
```

`:437` 結尾那行的 `九支共用函式庫自我測試（verify_common／…／getevent_touch）` 改成 `十支共用函式庫自我測試（verify_common／audio_stats／load_sentinel／guest_fps／gui_session／backpressure／input_latency／wake／getevent_touch／emu_instances）`。

- [ ] **Step 7: 閘門 4 的 lint 單獨跑一次（不必跑整支 ci.sh）**

Run（在 `app/` 下）：

```bash
python3 - <<'PY'
import re, pathlib
pat = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F\s]')
for p in [pathlib.Path("scripts/lib/emu_instances.sh"), pathlib.Path("scripts/lib/emu_selftest.sh")]:
    for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("#"): continue
        for m in pat.finditer(line): print(f"{p}:{i}: {m.group()}")
print("lint done")
PY
```
Expected: 只印 `lint done`。

- [ ] **Step 8: Commit**

```bash
git add app/scripts/lib/emu_instances.sh app/scripts/lib/emu_selftest.sh app/scripts/ci.sh
git commit -m "feat: emu.sh 多實例純函式層與自我測試納入閘門 7"
```

### Task 2: `emu.sh` 接上 `-n`、依埠判斷執行中、`status` 列全部

**Files:**
- Modify: `app/scripts/emu.sh`（全檔；下面是完整新內容）

**Interfaces:**
- Consumes（Task 1）：`EMU_DEFAULT_INSTANCES`、`emu_resolve`、`emu_table_check`、`emu_running_instances`、`emu_is_running`、`emu_avd_conflict`。
- Produces（Task 8 用）：`./scripts/emu.sh [-n <名稱>] [start|stop|status]`；`-n` 缺名稱或名稱未知退出碼 2；`start` 遇到同 AVD 在別的埠上退出碼 1；`status` 沒有任何實例退出碼 1。環境變數 `MIRAGE_INSTANCES` 整份覆寫實例表（只在帶 `-n` 時讀）。

這支腳本的測試是 Task 1 的自我測試（判斷邏輯全在那裡）加上這裡的手動驗證；start／stop 需要真模擬器，放到 Task 8 一起驗。

- [ ] **Step 1: 先記錄現況（改之前的對照）**

Run: `cd app && ./scripts/emu.sh status; echo "rc=$?"`
Expected: 開發機上目前有一台在跑時印 `執行中：emulator-5554（開機完成）`…，`rc=0`；沒有時印 `未執行`、`rc=1`。把輸出留著，Step 4 比對。

- [ ] **Step 2: 重寫 `emu.sh`**

```bash
#!/usr/bin/env bash
# 模擬器的單一入口：start（冪等）／stop／status。
#
# **存在的理由**：量測用的 emulator 一直是人工啟動的，沒有任何腳本負責它，
# 於是每次的旗標與埠號都靠人記得。今天實測過幾個會咬人的點：
#   - 不指定 `-grpc` 會拿到隨機埠（實測 54098），Mirage 與所有 verify_* 都連不上。
#   - 沒有 `-no-snapshot-save`，每次關閉會寫約 3.8G 的快照，磁碟很快見底。
#   - 用快照開機會帶著上次的狀態，量測結果不可比（音訊崩潰態會被一起帶進來）。
#   - 只給 `-grpc` 會綁在 `[::]`、不驗證，整個區域網路都能操作模擬器（D73）。
#     加 `-grpc-use-token` 後改綁 127.0.0.1 並要求 token；Mirage 與 tools/probe
#     會自己從探索檔讀 token，phase0/harness 的舊腳本則連不上（見該目錄 README）。
#
# ⚠️ 埠號刻意用 5554／8554：`app/scripts/` 底下多數 verify_* 預設這組。
# `tools/probe/lib/targets.py` 的 `game` 用的是 5556／8556，兩套慣例並存，
# 用 probe 時要自己覆寫。
#
# **多開（2026-09-12，docs/specs/2026-09-12-multi-instance-design.md §3.2）**：
#   `-n <名稱>` 選一台。名稱就是 AVD 名稱，對應的埠在 lib/emu_instances.sh 的實例表
#   （預設 mirage-game:5554:8554 mirage-poc:5556:8556，可用 MIRAGE_INSTANCES 整份覆寫）。
#   不帶 -n 時與以前一模一樣：MIRAGE_AVD／MIRAGE_PORT／MIRAGE_GRPC 或預設值。帶 -n 時
#   這三個環境變數被忽略——同時吃兩邊會讓名稱與埠號靜默對不上。
#   「有沒有在跑」比對的是這台的 console 埠，不是任何 qemu 行程；stop 只殺這台。
#   同一個 AVD 不能開第二台（規格 §3.1：每台各自一個 AVD），start 會先擋。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/emu_instances.sh"
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
EMULATOR="$SDK/emulator/emulator"
ADB="$SDK/platform-tools/adb"

NAME=""
if [ "${1:-}" = "-n" ]; then
    NAME="${2:-}"
    if [ -z "$NAME" ]; then echo "❌ -n 後面要接實例名稱" >&2; exit 2; fi
    shift 2
fi
if [ -n "$NAME" ]; then
    TABLE="${MIRAGE_INSTANCES:-$EMU_DEFAULT_INSTANCES}"
    emu_table_check "$TABLE" || exit 2
    TRIPLET=$(emu_resolve "$NAME" "$TABLE") || exit 2
    read -r AVD PORT GRPC <<< "$TRIPLET"
else
    AVD="${MIRAGE_AVD:-mirage-game}"
    PORT="${MIRAGE_PORT:-5554}"
    GRPC="${MIRAGE_GRPC:-8554}"
fi
SERIAL="emulator-${PORT}"
# 每台一個 log：兩台共用同一個檔會互相蓋掉。5554 的檔名因此從 mirage-emu.log 變成
# mirage-emu-5554.log——全 repo 沒有任何腳本讀這個檔（2026-09-12 grep 過），可以改。
LOG="${TMPDIR:-/tmp}/mirage-emu-${PORT}.log"

ps_lines() { pgrep -fl qemu-system 2>/dev/null; }
booted_on() { [ "$("$ADB" -s "$1" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }
booted() { booted_on "$SERIAL"; }
running() { emu_is_running "$(ps_lines)" "$PORT"; }
# gRPC 綁在哪個位址：`*` 表示對整個區域網路開放（沒用 -grpc-use-token 啟動的舊實例）。
grpc_bind() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $9}'; }
warn_if_open() {
  case "$(grpc_bind "$1")" in
    \*:*) echo "⚠️ gRPC 綁在 $(grpc_bind "$1")，對區域網路開放且沒有驗證。請 stop 後重新 start。" >&2 ;;
  esac
}
foreground_on() {
  "$ADB" -s "$1" shell dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity | grep -oE '[a-z][a-z.]+/[A-Za-z.]+' | head -1
}

case "${1:-start}" in
  start)
    if running && booted; then echo "✅ 已在執行且開機完成（${SERIAL}，gRPC ${GRPC}）"; warn_if_open "$GRPC"; exit 0; fi
    if running; then echo "⏳ 已在執行，等待開機完成…"; else
      if other=$(emu_avd_conflict "$(ps_lines)" "$AVD" "$PORT"); then
        echo "❌ AVD ${AVD} 已在 console 埠 ${other} 上執行。同一個 AVD 不能開第二台——每台要各自一個 AVD（規格 §3.1），用 tools/provision 加一台再以 -n 指定。" >&2
        exit 1
      fi
      echo "▶︎ 啟動 ${AVD}（port ${PORT}／gRPC ${GRPC}，冷開機、離開不存快照）"
      nohup "$EMULATOR" -avd "$AVD" -no-snapshot -port "$PORT" -grpc "$GRPC" -grpc-use-token \
        < /dev/null > "$LOG" 2>&1 &
      sleep 8
    fi
    for _ in $(seq 1 60); do booted && { echo "✅ 開機完成（${SERIAL}）"; exit 0; }; sleep 3; done
    echo "❌ 90 秒內未開機完成，log：${LOG}" >&2; exit 1
    ;;
  stop)
    running || { echo "已經沒有在執行（${SERIAL}）"; exit 0; }
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1
    for _ in $(seq 1 30); do running || { echo "✅ 已停止（${SERIAL}，未寫快照）"; exit 0; }; sleep 2; done
    echo "⚠️ 30 秒內沒停下來。**不要用 kill -9**（會留孤兒行程），再等或手動關視窗。" >&2; exit 1
    ;;
  status)
    LINES=$(emu_running_instances "$(ps_lines)")
    if [ -z "$LINES" ]; then echo "未執行"; exit 1; fi
    while read -r pid avd port grpc; do
      serial="emulator-${port}"
      if booted_on "$serial"; then st="開機完成"; else st="開機中"; fi
      printf '執行中：%s（%s，AVD %s，pid %s）\n' "$serial" "$st" "$avd" "$pid"
      if [ "$grpc" = "?" ]; then
        printf '  gRPC：未指定 -grpc，隨機埠，Mirage 連不上\n'
      else
        printf '  gRPC %s 綁定：%s\n' "$grpc" "$(grpc_bind "$grpc")"; warn_if_open "$grpc"
      fi
      printf '  前景：%s\n' "$(foreground_on "$serial")"
    done <<< "$LINES"
    printf '磁碟可用：%s\n' "$(df -h / | tail -1 | awk '{print $4}')"
    ;;
  *) echo "用法：$0 [-n <實例名稱>] [start|stop|status]" >&2; exit 2 ;;
esac
```

- [ ] **Step 3: 語法與 lint**

Run: `bash -n app/scripts/emu.sh && echo syntax-ok`
Expected: `syntax-ok`。

Run: Task 1 Step 7 那段 python，把檔案清單換成 `["scripts/emu.sh"]`。
Expected: 只印 `lint done`。

- [ ] **Step 4: 手動驗證（不需要第二台）**

Run（在 `app/` 下）：

```bash
./scripts/emu.sh -n; echo "rc=$?"
./scripts/emu.sh -n nope status; echo "rc=$?"
MIRAGE_INSTANCES="a:5554:8554 a:5556:8556" ./scripts/emu.sh -n a status; echo "rc=$?"
./scripts/emu.sh status; echo "rc=$?"
./scripts/emu.sh bogus; echo "rc=$?"
```
Expected：
1. `❌ -n 後面要接實例名稱`、`rc=2`。
2. `❌ 未知的實例名稱：nope。可用：mirage-game, mirage-poc`、`rc=2`。
3. `❌ 實例表裡 AVD a 出現兩次…`、`rc=2`。
4. 與 Step 1 同一台：`執行中：emulator-5554（開機完成，AVD mirage-game，pid N）`、`  gRPC 8554 綁定：127.0.0.1:8554`、前景一行、磁碟一行，`rc=0`；沒有模擬器時 `未執行`、`rc=1`。
5. `用法：./scripts/emu.sh [-n <實例名稱>] [start|stop|status]`、`rc=2`。

若開發機上有一台 5554 在跑，再驗 AVD 衝突（不會真的啟動第二台）：

```bash
MIRAGE_INSTANCES="mirage-game:5554:8554 mirage-game:5556:8556" ./scripts/emu.sh -n mirage-game start; echo "rc=$?"
```
Expected: 這個表本身就重複，`emu_table_check` 先擋：`❌ 實例表裡 AVD mirage-game 出現兩次…`、`rc=2`。執行期的衝突（表合法但那台 AVD 已在別的埠上跑）由 `emu_avd_conflict` 擋，Task 1 的自我測試釘住它，活體在 Task 8 順帶驗（兩台起來後 `MIRAGE_INSTANCES="mirage-game:5558:8558" ./scripts/emu.sh -n mirage-game start` 必須印 `❌ AVD mirage-game 已在 console 埠 5554 上執行…` 且 `rc=1`）。

- [ ] **Step 5: 確認 mac/*.command 不受影響**

Run: `grep -n 'emu.sh' app/scripts/mac/*.command`
Expected: 只有 `./emu.sh start` 與 `./emu.sh stop`，不帶 `-n`——走的是 `else` 分支，三個變數與舊檔 `:20-22` 的定義逐字相同。

- [ ] **Step 6: Commit**

```bash
git add app/scripts/emu.sh
git commit -m "feat: emu.sh 支援 -n 多實例，依 console 埠判斷執行中並列出全部實例"
```

---

### Task 3: `EmulatorInstance` 與 `EmulatorDiscovery.listInstances`

**Files:**
- Create: `app/Sources/MirageCore/EmulatorInstance.swift`
- Test: `app/Tests/MirageCoreTests/EmulatorInstanceTests.swift`

**Interfaces:**
- Consumes：`EmulatorDiscovery.DiscoveryFile`（`EmulatorDiscovery.swift:6-10`）、`parseINI(_:)`（`:12`）、`pid(from:)`（`:24`）、`pidIsAlive(_:)`（`:58`）、`runningDirectory`（`:68`）、`readFiles(in:)`（`:73`）。
- Produces：
  ```swift
  public struct EmulatorInstance: Sendable, Equatable, Hashable {
      public let avdName: String
      public let consolePort: Int
      public let grpcPort: Int
      public let pid: Int32
      public init(avdName: String, consolePort: Int, grpcPort: Int, pid: Int32)
  }
  extension EmulatorDiscovery {
      static func instances(files: [DiscoveryFile], isAlive: (Int32) throws -> Bool) -> [EmulatorInstance]
      static func listInstances(directory: URL = runningDirectory,
                                isAlive: (Int32) throws -> Bool = pidIsAlive,
                                readFiles: (URL) throws -> [DiscoveryFile] = EmulatorDiscovery.readFiles(in:)) -> [EmulatorInstance]
      public static func instances() -> [EmulatorInstance]   // 每次呼叫重讀，不快取
  }
  ```
  `listInstances` 維持 internal（與 `discoverToken` 同一層）：它的參數型別含 internal 的 `DiscoveryFile`，Swift 不允許 public 簽章露出 internal 型別。Shell 層用 `instances()`，測試用 `@testable`。

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageCoreTests/EmulatorInstanceTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

@Suite("EmulatorDiscovery.listInstances")
struct EmulatorInstanceTests {
    /// 與 EmulatorDiscoveryTests.sample 同一份真實格式（37.1.11.0 的 pid_*.ini）。
    private let first = """
        emulator.build=15917651
        avd.id=mirage-game
        emulator.version=37.1.11.0
        port.serial=5554
        port.adb=5555
        avd.name=mirage-game
        avd.dir=/example/.android/avd/mirage-game.avd
        cmdline="/example/qemu-system-aarch64" "-avd" "mirage-game" "-no-snapshot" "-port" "5554" "-grpc" "8554" "-grpc-use-token"
        grpc.token=fake-token=only
        launcher.dir=/example/emulator
        grpc.allowlist=/example/emulator/lib/emulator_access.json
        grpc.port=8554
        """
    private let second = """
        avd.id=mirage-poc
        port.serial=5556
        port.adb=5557
        avd.name=mirage-poc
        grpc.token=fake-second
        grpc.port=8556
        """

    private func file(_ pid: Int, text: String, modified: TimeInterval = 1)
        -> EmulatorDiscovery.DiscoveryFile {
        .init(name: "pid_\(pid).ini", text: text, modified: modified)
    }

    @Test func listsEveryLiveInstanceSortedByConsolePort() {
        let files = [file(200, text: second), file(100, text: first)]
        let got = EmulatorDiscovery.instances(files: files, isAlive: { _ in true })
        #expect(got == [
            EmulatorInstance(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554, pid: 100),
            EmulatorInstance(avdName: "mirage-poc", consolePort: 5556, grpcPort: 8556, pid: 200),
        ])
    }

    @Test func deadPIDIsDropped() {
        let files = [file(100, text: first), file(200, text: second)]
        let got = EmulatorDiscovery.instances(files: files, isAlive: { $0 != 200 })
        #expect(got.map(\.pid) == [100])
    }

    @Test(arguments: [
        "avd.name=x\ngrpc.port=8554",                      // 缺 port.serial
        "avd.name=x\nport.serial=5554",                    // 缺 grpc.port
        "port.serial=5554\ngrpc.port=8554",                // 缺 avd.name
        "avd.name=x\nport.serial=abc\ngrpc.port=8554",     // 埠不是整數
    ])
    func incompleteFileIsSkipped(text: String) {
        #expect(EmulatorDiscovery.instances(files: [file(1, text: text)], isAlive: { _ in true }).isEmpty)
    }

    @Test func invalidFilenameIsIgnored() {
        let bad = EmulatorDiscovery.DiscoveryFile(name: "other.ini", text: first, modified: 1)
        #expect(EmulatorDiscovery.instances(files: [bad], isAlive: { _ in true }).isEmpty)
    }

    /// 同一個 console 埠留下兩份探索檔（前一次崩潰沒清）：只留 modified 最新的那份。
    @Test func newestFileWinsForTheSameConsolePort() {
        let stale = file(100, text: first, modified: 1)
        let fresh = file(300, text: first, modified: 2)
        for order in [[stale, fresh], [fresh, stale]] {
            let got = EmulatorDiscovery.instances(files: order, isAlive: { _ in true })
            #expect(got.map(\.pid) == [300])
        }
    }

    @Test func livenessErrorYieldsNothing() {
        let got = EmulatorDiscovery.instances(files: [file(100, text: first)], isAlive: { _ in
            throw CocoaError(.fileReadUnknown)
        })
        #expect(got.isEmpty)
    }

    @Test func readErrorYieldsEmptyList() {
        let directory = URL(fileURLWithPath: "/fake/running")
        let got = EmulatorDiscovery.listInstances(directory: directory, isAlive: { _ in true },
                                                  readFiles: { url in
            #expect(url == directory)
            throw CocoaError(.fileNoSuchFile)
        })
        #expect(got.isEmpty)
    }

    @Test func injectedIOIsReadOnEveryCall() {
        let directory = URL(fileURLWithPath: "/fake/running")
        var current = [file(100, text: first)]
        let reader: (URL) throws -> [EmulatorDiscovery.DiscoveryFile] = { _ in current }
        #expect(EmulatorDiscovery.listInstances(directory: directory, isAlive: { _ in true },
                                                readFiles: reader).count == 1)
        current = [file(100, text: first), file(200, text: second)]
        #expect(EmulatorDiscovery.listInstances(directory: directory, isAlive: { _ in true },
                                                readFiles: reader).count == 2)
    }
}
```

- [ ] **Step 2: 跑測試確認編不過**

Run: `cd app && swift build --build-tests 2>&1 | grep -E 'error:' | head -5`
Expected: `cannot find 'EmulatorInstance' in scope`／`type 'EmulatorDiscovery' has no member 'instances'`。

- [ ] **Step 3: 實作**

`app/Sources/MirageCore/EmulatorInstance.swift`：

```swift
import Foundation

/// 探索檔裡一台活著的模擬器。三個值就是 emu.sh 的實例三元組，加上用來判活的 pid。
///
/// 純值型別、無 I/O。`selectToken` 只回答「這個 gRPC 埠的 token 是什麼」，這裡回答的是
/// 「現在有哪幾台」——同一份 `pid_*.ini`、同一組解析函式，只是不篩埠。
public struct EmulatorInstance: Sendable, Equatable, Hashable {
    public let avdName: String
    public let consolePort: Int
    public let grpcPort: Int
    public let pid: Int32

    public init(avdName: String, consolePort: Int, grpcPort: Int, pid: Int32) {
        self.avdName = avdName
        self.consolePort = consolePort
        self.grpcPort = grpcPort
        self.pid = pid
    }
}

extension EmulatorDiscovery {
    /// 純選擇：只留活著的、欄位齊全的；同一個 console 埠有多份檔時留 modified 最新的。
    /// 判活閉包拋錯 → 整份回空（與 `selectToken` 的 catch 語意一致：不猜）。
    static func instances(
        files: [DiscoveryFile], isAlive: (Int32) throws -> Bool
    ) -> [EmulatorInstance] {
        do {
            var newestByPort: [Int: (file: DiscoveryFile, instance: EmulatorInstance)] = [:]
            for file in files {
                guard let pid = pid(from: file.name) else { continue }
                let fields = parseINI(file.text)
                guard let avd = fields["avd.name"], !avd.isEmpty,
                      let console = fields["port.serial"].flatMap(Int.init),
                      let grpc = fields["grpc.port"].flatMap(Int.init),
                      try isAlive(pid) else { continue }
                let candidate = EmulatorInstance(avdName: avd, consolePort: console,
                                                 grpcPort: grpc, pid: pid)
                if let previous = newestByPort[console],
                   previous.file.modified > file.modified ||
                    (previous.file.modified == file.modified && previous.file.name >= file.name) {
                    continue
                }
                newestByPort[console] = (file, candidate)
            }
            return newestByPort.values.map(\.instance).sorted { $0.consolePort < $1.consolePort }
        } catch {
            return []
        }
    }

    /// I/O 可注入，簽章與 `discoverToken` 同形。讀不到目錄回空清單，不擲錯——
    /// 選單列拿空清單就顯示「沒有其他模擬器」，那正是使用者該看到的。
    static func listInstances(
        directory: URL = runningDirectory,
        isAlive: (Int32) throws -> Bool = pidIsAlive,
        readFiles: (URL) throws -> [DiscoveryFile] = EmulatorDiscovery.readFiles(in:)
    ) -> [EmulatorInstance] {
        do {
            return instances(files: try readFiles(directory), isAlive: isAlive)
        } catch {
            return []
        }
    }

    /// 每次呼叫重讀探索目錄；不快取，理由同 `token(port:)`。
    public static func instances() -> [EmulatorInstance] {
        listInstances()
    }
}
```

- [ ] **Step 4: 跑測試確認全綠**

Run: `cd app && MIRAGE_PORT=45999 swift test --filter EmulatorInstanceTests 2>&1 | tail -5`
Expected: `Test run with 12 tests passed`（8 個函式，其中 `incompleteFileIsSkipped` 4 個引數）。既有的 `EmulatorDiscoveryTests` 也要跑一次確認沒動到：`swift test --filter EmulatorDiscoveryTests 2>&1 | tail -3` → 全過。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/EmulatorInstance.swift app/Tests/MirageCoreTests/EmulatorInstanceTests.swift
git commit -m "feat: EmulatorDiscovery 可列出探索檔裡所有活著的模擬器實例"
```

### Task 4: `EmulatorClient.setEndpoint` 與 `stop()` 等舊迴圈結束

**Files:**
- Modify: `app/Sources/MirageCore/EmulatorClient.swift:7-8`（欄位）、`:105-106`（init 賦值）、`:169-178`（`stop()`）、`:297`（`ensureChannel` 用 endpoint）、`:203` 之後（新增三個 getter 與 `setEndpoint`）
- Test: `app/Tests/MirageCoreTests/EmulatorClientEndpointTests.swift`（新增）

**Interfaces:**
- Consumes：`EmulatorEndpoint`（`EmulatorEndpoint.swift:8-25`）、測試假件 `MockTransport`／`ScriptedProbe`／`LatestFrameBox`／`CountGate`（`EmulatorClientReconnectTests.swift:6-58`、`HealthProbeTests.swift:15-25`、`TestGates.swift:13`）。
- Produces（Task 6 用）：
  ```swift
  extension EmulatorClient {   // 實際寫在 actor 本體
      public var currentEndpoint: EmulatorEndpoint { get }
      public var isRunning: Bool { get }
      public var requestedStreamSize: (w: Int, h: Int) { get }
      @discardableResult public func setEndpoint(_ target: EmulatorEndpoint) -> Bool   // running 時回 false 不改
  }
  ```
  `init(host:port:…)`、`start(box:width:height:)`、`stop()` 的簽章不變；`stop()` 回來時舊迴圈保證已結束。

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageCoreTests/EmulatorClientEndpointTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

/// 切換模擬器 = stop → setEndpoint → start。這裡守的是 actor 自己的三條不變式：
/// 端點只在停下來時可換、stop() 回來時舊迴圈已結束、串流尺寸跨越 stop/start 保留。
/// 端點都指向沒人監聽的埠（CI 的 MIRAGE_PORT 與保留埠 1），不需要模擬器。
@Suite(.timeLimit(.minutes(1))) struct EmulatorClientEndpointTests {
    private static let deadA = EmulatorEndpoint(host: "localhost", port: EmulatorClient.defaultEndpoint.port)
    private static let deadB = EmulatorEndpoint(host: "localhost", port: 1)

    /// 版本 <37（見 ScriptedProbe 的說明）：走 makeTransport 的假件，不建真的 MMAP transport。
    private func makeClient() -> EmulatorClient {
        EmulatorClient(host: Self.deadA.host, port: Self.deadA.port,
                       makeTransport: { _ in MockTransport([.yieldThenHang(1)]) },
                       makeHealthProbe: { _ in ScriptedProbe([]) },
                       sleeper: { _ in }, randomSource: { 0.5 })
    }

    @Test func initialEndpointComesFromInit() async {
        let client = makeClient()
        #expect(await client.currentEndpoint == Self.deadA)
        #expect(await !client.isRunning)
    }

    @Test func setEndpointWhileStoppedChangesTarget() async {
        let client = makeClient()
        #expect(await client.setEndpoint(Self.deadB))
        #expect(await client.currentEndpoint == Self.deadB)
    }

    /// 在跑的時候換端點會讓「狀態說已切換、畫面還是舊那台」——必須拒絕，且不改。
    @Test func setEndpointWhileRunningIsRefusedUntilStopped() async {
        let client = makeClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        #expect(await client.isRunning)
        #expect(await !client.setEndpoint(Self.deadB))
        #expect(await client.currentEndpoint == Self.deadA)

        await client.stop()
        #expect(await !client.isRunning)
        #expect(await client.setEndpoint(Self.deadB))
        #expect(await client.currentEndpoint == Self.deadB)
    }

    /// 切換後重新 start 要沿用最後一次要求的尺寸——全螢幕下 MirrorView 已把尺寸換成
    /// 內容矩形，退回 540x1200 會讓畫面糊掉且沒有訊號（resize 事件不會再來一次）。
    @Test func requestedStreamSizeSurvivesStop() async {
        let client = makeClient()
        await client.start(box: LatestFrameBox(), width: 900, height: 2000)
        await client.setStreamSize(width: 1080, height: 1800)
        await client.stop()
        let size = await client.requestedStreamSize
        #expect(size.w == 1080)
        #expect(size.h == 1800)
    }

    /// 設計決定 2：stop() 回來時舊迴圈必須已結束。
    ///
    /// 探測永遠失敗 → 迴圈卡在退避的 sleeper。sleeper 被取消後**故意阻塞 50ms 才計數**：
    /// stop() 若沒等迴圈，它在取消後幾微秒就回來，計數還是 0；等了的話一定是 1。
    /// 這樣不等的版本是確定性的紅，不是偶爾紅。
    @Test func stopWaitsForTheOldLoopToFinish() async throws {
        let ended = CountGate()
        let client = EmulatorClient(
            host: Self.deadA.host, port: Self.deadA.port,
            makeTransport: { _ in MockTransport([]) },
            makeHealthProbe: { _ in ScriptedProbe(Array(repeating: .failed, count: 1000)) },
            sleeper: { d in
                do { try await Task.sleep(for: d) } catch {
                    Thread.sleep(forTimeInterval: 0.05)
                    ended.increment()
                    throw error
                }
            },
            randomSource: { 0.5 })
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .milliseconds(100))   // 讓迴圈走到第一次退避（500ms）
        await client.stop()
        #expect(ended.current == 1)
        #expect(await !client.isRunning)
    }

    /// stop() 之後 client 不知道任何 guest 的事；下一台的解析度要等它自己的探測。
    @Test func stopForgetsGuestDisplay() async throws {
        let probe = ScriptedProbe([.healthy(EmulatorInfo(version: "36.6.11.0", display: (w: 1080, h: 2400)))])
        let mock = MockTransport([.yieldThenHang(1)])
        let client = EmulatorClient(host: Self.deadA.host, port: Self.deadA.port,
                                    makeTransport: { _ in mock },
                                    makeHealthProbe: { _ in probe },
                                    sleeper: { _ in }, randomSource: { 0.5 })
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        await mock.subscribeGate.wait(for: 1)
        let before = await client.displaySize
        #expect(before?.w == 1080)
        await client.stop()
        #expect(await client.displaySize == nil)
    }
}
```

- [ ] **Step 2: 跑測試確認編不過**

Run: `cd app && swift build --build-tests 2>&1 | grep -E 'error:' | head -5`
Expected: `value of type 'EmulatorClient' has no member 'currentEndpoint'`（以及 `isRunning`／`setEndpoint`／`requestedStreamSize`）。

- [ ] **Step 3: 實作**

`EmulatorClient.swift:7-8` 的兩個 `let` 換成一個 `var`：

```swift
    /// 連線目標。切換模擬器時由 `setEndpoint` 改寫；`ensureChannel()` 每次重建 channel 都讀它。
    private var endpoint: EmulatorEndpoint
```

`:105-106` 的 `self.host = host` / `self.port = port` 換成：

```swift
        self.endpoint = EmulatorEndpoint(host: host, port: port)
```

`:297` 的 `try GrpcChannelBox(host: host, port: port)` 換成：

```swift
                let boxCh = try GrpcChannelBox(host: endpoint.host, port: endpoint.port)
```

`:169-178` 的 `stop()` 換成：

```swift
    public func stop() async {
        running = false
        breakCont?.yield()          // 喚醒卡在 connectedRun 的迴圈
        loopTask?.cancel()          // 喚醒卡在 sleeper/probe 的迴圈
        // **等舊迴圈真的結束**（2026-09-12，模擬器切換）。原本這裡不等：迴圈若正卡在
        // `probe(timeout:)`，stop() 回來、緊接的 start() 把 running 設回 true 之後它才醒來，
        // runConnectionLoop 的 `if !running { break }` 看到的是 true，接著 dropChannel()
        // 拆掉的是**新迴圈**剛建好的 channel，然後兩條迴圈同時跑。單台時 stop 之後從來
        // 沒有立刻 start 過，所以沒踩到；切換會每次都踩。迴圈的每個 await 之後都檢查
        // running，上面兩行保證它最多再等一次 probeTimeout 就走到那個檢查。
        await loopTask?.value
        loopTask = nil
        await pump.detach()
        detachAudio()
        _ = step(.stopRequested)    // → .disconnected
        dropChannel()
        // 停下來的 client 不知道任何 guest 的事：下一台的解析度與版本要等它自己的探測。
        // 留著舊值，sendTap 會在新 channel 建好、探測還沒回來的那一秒用舊解析度換算座標。
        guestDisplay = nil
        emulatorVersion = ""
    }
```

`:203`（`displaySize`）之後加：

```swift
    /// 目前的連線目標。切換模擬器時由 `setEndpoint` 改寫。
    public var currentEndpoint: EmulatorEndpoint { endpoint }

    /// 連線迴圈是否在跑（`start()` 之後、`stop()` 之前）。
    public var isRunning: Bool { running }

    /// 最近一次要求的串流尺寸（`start` 或 `setStreamSize` 設的）。切換模擬器後重新 `start`
    /// 要沿用它——全螢幕下 MirrorView 已把尺寸換成內容矩形，退回預設會讓畫面糊掉且沒有訊號。
    public var requestedStreamSize: (w: Int, h: Int) { streamSize }

    /// 換連線目標。**只在停下來時允許。** 迴圈在跑時換，舊 channel 會用到下一次重連才換——
    /// 那是「狀態說已切換、畫面還是舊那台」的無訊號故障。回 false 表示沒換；印出來的
    /// 理由與 `start()` 對重複呼叫的處理相同：上游不該走到這裡，走到了要有訊號。
    @discardableResult
    public func setEndpoint(_ target: EmulatorEndpoint) -> Bool {
        guard !running else {
            print("[conn] setEndpoint(\(target.host):\(target.port)) 被忽略：連線迴圈在跑，先 stop() 再換")
            return false
        }
        endpoint = target
        return true
    }
```

- [ ] **Step 4: 跑新測試與所有既有 client 測試**

Run: `cd app && MIRAGE_PORT=45999 swift test --filter 'EmulatorClientEndpointTests' 2>&1 | tail -5`
Expected: 6 tests passed。

Run: `cd app && MIRAGE_PORT=45999 swift test --filter 'EmulatorClient' 2>&1 | tail -5`
Expected: 全過。**若這裡有測試卡住**，是某個假的 probe 或 sleeper 不理會取消（`stop()` 現在會等它）——修那個假件讓它可取消，不要拿掉 `await loopTask?.value`。

- [ ] **Step 5: 突變檢查**

把 `await loopTask?.value` 暫時註解掉，跑 `swift test --filter stopWaitsForTheOldLoopToFinish`：必須紅（`ended.current == 1` 失敗，得到 0）。還原後再跑一次確認綠。

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MirageCore/EmulatorClient.swift app/Tests/MirageCoreTests/EmulatorClientEndpointTests.swift
git commit -m "feat: EmulatorClient 可在停止後換端點，stop 等舊連線迴圈結束"
```

---

### Task 5: `InstanceMenu.entries` 純函式（子選單內容的決策）

**Files:**
- Create: `app/Sources/MirageShell/Lifecycle/InstanceMenu.swift`
- Test: `app/Tests/MirageShellTests/InstanceMenuTests.swift`

**Interfaces:**
- Consumes：`EmulatorInstance`（Task 3）、`EmulatorEndpoint`。
- Produces（Task 6、Task 7 用）：
  ```swift
  struct InstanceMenuEntry: Equatable {
      let title: String
      let instance: EmulatorInstance?   // nil = 「沒有其他模擬器」的停用佔位
      let isCurrent: Bool
      var isEnabled: Bool { instance != nil }
  }
  enum InstanceMenu {
      static let placeholderTitle = "沒有其他模擬器"
      static func entries(instances: [EmulatorInstance], current: EmulatorEndpoint) -> [InstanceMenuEntry]
      static func title(for instance: EmulatorInstance) -> String   // "mirage-game（console 5554／gRPC 8554）"
  }
  ```

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageShellTests/InstanceMenuTests.swift`：

```swift
import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct InstanceMenuTests {
    private let game = EmulatorInstance(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554, pid: 1)
    private let poc = EmulatorInstance(avdName: "mirage-poc", consolePort: 5556, grpcPort: 8556, pid: 2)
    private let onGame = EmulatorEndpoint(host: "localhost", port: 8554)

    @Test func listsAllInstancesAndMarksCurrentByGrpcPort() {
        let entries = InstanceMenu.entries(instances: [game, poc], current: onGame)
        #expect(entries == [
            InstanceMenuEntry(title: "mirage-game（console 5554／gRPC 8554）", instance: game, isCurrent: true),
            InstanceMenuEntry(title: "mirage-poc（console 5556／gRPC 8556）", instance: poc, isCurrent: false),
        ])
        #expect(entries.allSatisfy(\.isEnabled))
    }

    /// 規格 §3.3：沒有其他實例時子選單只有一個停用項。
    @Test func onlyCurrentInstanceYieldsDisabledPlaceholder() {
        let entries = InstanceMenu.entries(instances: [game], current: onGame)
        #expect(entries.count == 1)
        #expect(entries[0].title == InstanceMenu.placeholderTitle)
        #expect(entries[0].instance == nil)
        #expect(!entries[0].isEnabled)
        #expect(!entries[0].isCurrent)
    }

    @Test func emptyListYieldsDisabledPlaceholder() {
        let entries = InstanceMenu.entries(instances: [], current: onGame)
        #expect(entries.map(\.title) == [InstanceMenu.placeholderTitle])
        #expect(!entries[0].isEnabled)
    }

    /// Mirage 指向的埠沒有探索檔（例如 MIRAGE_PORT 指到一台舊式啟動的實例）：
    /// 全部列出、沒有一個打勾——使用者仍然可以切到有探索檔的那台。
    @Test func currentNotDiscoveredListsEverythingUnchecked() {
        let entries = InstanceMenu.entries(instances: [game, poc],
                                           current: EmulatorEndpoint(host: "localhost", port: 8560))
        #expect(entries.map(\.isCurrent) == [false, false])
        #expect(entries.allSatisfy(\.isEnabled))
    }

    /// 只看 gRPC 埠、不看 host：探索檔只描述本機實例，host 由 MIRAGE_HOST 決定且切換不改它。
    @Test func currentIsMatchedByPortOnly() {
        let entries = InstanceMenu.entries(instances: [game, poc],
                                           current: EmulatorEndpoint(host: "127.0.0.1", port: 8556))
        #expect(entries.map(\.isCurrent) == [false, true])
    }
}
```

- [ ] **Step 2: 跑測試確認編不過**

Run: `cd app && swift build --build-tests 2>&1 | grep -E 'error:' | head -3`
Expected: `cannot find 'InstanceMenu' in scope`。

- [ ] **Step 3: 實作**

`app/Sources/MirageShell/Lifecycle/InstanceMenu.swift`：

```swift
import MirageCore

/// 「切換模擬器」子選單的一列。`instance == nil` 是「沒有其他模擬器」的停用佔位。
struct InstanceMenuEntry: Equatable {
    let title: String
    let instance: EmulatorInstance?
    let isCurrent: Bool
    var isEnabled: Bool { instance != nil }
}

/// 子選單內容的純決策：實例清單＋目前端點 → 列表。無 AppKit、無 I/O，逐條單元測試。
///
/// 「目前那台」只比對 gRPC 埠：探索檔（`pid_*.ini`）只描述本機實例，host 由
/// `MIRAGE_HOST` 決定且切換不改它（見 `AppModel.switchInstance`）。
enum InstanceMenu {
    static let placeholderTitle = "沒有其他模擬器"

    static func title(for instance: EmulatorInstance) -> String {
        "\(instance.avdName)（console \(instance.consolePort)／gRPC \(instance.grpcPort)）"
    }

    static func entries(instances: [EmulatorInstance], current: EmulatorEndpoint) -> [InstanceMenuEntry] {
        let rows = instances.map { instance in
            InstanceMenuEntry(title: title(for: instance), instance: instance,
                              isCurrent: instance.grpcPort == current.port)
        }
        // 規格 §3.3：沒有**其他**實例時只剩一個停用項。只有目前那台也算沒有其他。
        guard rows.contains(where: { !$0.isCurrent }) else {
            return [InstanceMenuEntry(title: placeholderTitle, instance: nil, isCurrent: false)]
        }
        return rows
    }
}
```

- [ ] **Step 4: 跑測試確認全綠**

Run: `cd app && MIRAGE_PORT=45999 swift test --filter InstanceMenuTests 2>&1 | tail -3`
Expected: 5 tests passed。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageShell/Lifecycle/InstanceMenu.swift app/Tests/MirageShellTests/InstanceMenuTests.swift
git commit -m "feat: 切換模擬器子選單內容的純決策 InstanceMenu"
```

### Task 6: 選單列「切換模擬器」子選單

**Files:**
- Modify: `app/Sources/MirageShell/Lifecycle/MenuBarController.swift:14-15`（屬性）、`:18-23`（回呼）、`:50-52`（init 建 menu）、`:62-64`（加子選單項）、`:99-108`（`menuNeedsUpdate`）、`:119-122` 之後（新增 `instanceTapped` 與 `populate`）
- Test: `app/Tests/MirageShellTests/MenuBarInstanceMenuTests.swift`（新增）

**Interfaces:**
- Consumes：`InstanceMenuEntry`、`InstanceMenu`（Task 5）、`EmulatorInstance`（Task 3）。
- Produces（Task 7 用）：
  ```swift
  final class MenuBarController {
      var instanceEntries: (() -> [InstanceMenuEntry])?          // 子選單展開前呼叫，拿內容
      var onSwitchInstance: ((EmulatorInstance) -> Void)?        // 使用者選了某一台
      static func populate(instanceMenu menu: NSMenu, entries: [InstanceMenuEntry],
                           target: AnyObject?, action: Selector?)  // 純佈局，測試用
  }
  ```

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageShellTests/MenuBarInstanceMenuTests.swift`：

```swift
import AppKit
import Testing
@testable import MirageCore
@testable import MirageShell

/// 只測 `populate`（static、吃一個 NSMenu）：建 `MenuBarController` 本身會在開發機的
/// 選單列放一個狀態列圖示（RESULTS-shell-target.md 的全域副作用清單），headless 測試不碰。
@MainActor
@Suite struct MenuBarInstanceMenuTests {
    private let game = EmulatorInstance(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554, pid: 1)
    private let poc = EmulatorInstance(avdName: "mirage-poc", consolePort: 5556, grpcPort: 8556, pid: 2)
    private let onGame = EmulatorEndpoint(host: "localhost", port: 8554)
    private let action = NSSelectorFromString("instanceTapped:")

    @Test func populateBuildsOneItemPerEntryWithCheckAndTarget() throws {
        let menu = NSMenu()
        let target = NSObject()
        let entries = InstanceMenu.entries(instances: [game, poc], current: onGame)

        MenuBarController.populate(instanceMenu: menu, entries: entries, target: target, action: action)

        #expect(menu.items.map(\.title) == entries.map(\.title))
        #expect(menu.items.map(\.state) == [.on, .off])
        #expect(menu.items.allSatisfy(\.isEnabled))
        #expect(menu.items.allSatisfy { $0.target === target && $0.action == action })
        #expect(try #require(menu.items[1].representedObject as? EmulatorInstance) == poc)
    }

    /// 規格 §3.3：沒有其他實例 → 一個停用項，沒有 action、不打勾。
    @Test func placeholderIsSingleDisabledItem() {
        let menu = NSMenu()
        let entries = InstanceMenu.entries(instances: [game], current: onGame)

        MenuBarController.populate(instanceMenu: menu, entries: entries, target: NSObject(), action: action)

        #expect(menu.items.count == 1)
        #expect(menu.items[0].title == InstanceMenu.placeholderTitle)
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[0].action == nil)
        #expect(menu.items[0].target == nil)
        #expect(menu.items[0].state == .off)
    }

    /// 每次展開都重建：上一次的項目不得殘留（與「套用 profile」的 removeAllItems 同一條）。
    @Test func populateReplacesPreviousItems() {
        let menu = NSMenu()
        MenuBarController.populate(instanceMenu: menu,
                                   entries: InstanceMenu.entries(instances: [game, poc], current: onGame),
                                   target: NSObject(), action: action)
        #expect(menu.items.count == 2)

        MenuBarController.populate(instanceMenu: menu,
                                   entries: InstanceMenu.entries(instances: [], current: onGame),
                                   target: NSObject(), action: action)
        #expect(menu.items.map(\.title) == [InstanceMenu.placeholderTitle])
    }
}
```

- [ ] **Step 2: 跑測試確認編不過**

Run: `cd app && swift build --build-tests 2>&1 | grep -E 'error:' | head -3`
Expected: `type 'MenuBarController' has no member 'populate'`。

- [ ] **Step 3: 實作**

`MenuBarController.swift:15`（`private let forceMenu: NSMenu`）下面加：

```swift
    /// 「切換模擬器」子選單。內容每次展開前由 `instanceEntries` 重算（探索檔隨模擬器起停而變）。
    private let instanceMenu: NSMenu
```

`:23`（`onToggleFullScreen`）下面加：

```swift
    /// 模擬器多開（2026-09-12）：AppModel.setupInstanceMenu() 綁定。前者在子選單展開前
    /// 被呼叫、回傳要顯示的列；後者在使用者選了某一台時被呼叫。
    var instanceEntries: (() -> [InstanceMenuEntry])?
    var onSwitchInstance: ((EmulatorInstance) -> Void)?
```

`:50`（`forceMenu = NSMenu()`）下面加，並在 `:52`（`forceMenu.delegate = self`）下面加 delegate：

```swift
        forceMenu = NSMenu()
        instanceMenu = NSMenu()
        instanceMenu.autoenablesItems = false   // 停用與否由 populate 決定，不讓 AppKit 依 action 猜
        super.init()
        forceMenu.delegate = self
        instanceMenu.delegate = self
```

`:64`（`menu.addItem(muteItem)`）下面加：

```swift
        let instanceParent = NSMenuItem(title: "切換模擬器", action: nil, keyEquivalent: "")
        instanceParent.submenu = instanceMenu   // 與「套用 profile」同形：AppKit 自己畫 ▸
        menu.addItem(instanceParent)
```

`:99-108` 的 `menuNeedsUpdate` 改成：

```swift
    /// 兩個子選單都在展開前重算：「套用 profile」掃 profile 目錄、「切換模擬器」掃探索檔。
    /// 兩者都是「選單即時反映磁碟狀態」，不在 init 建一次。
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === instanceMenu {
            Self.populate(instanceMenu: instanceMenu, entries: instanceEntries?() ?? [],
                          target: self, action: #selector(instanceTapped(_:)))
            return
        }
        guard menu === forceMenu else { return }
        forceMenu.removeAllItems()
        for gameId in Self.availableGameIds() {
            let item = NSMenuItem(title: gameId, action: #selector(forceTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = gameId
            forceMenu.addItem(item)
        }
    }
```

`:122`（`forceTapped` 結尾）下面加：

```swift
    @objc private func instanceTapped(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? EmulatorInstance else { return }
        onSwitchInstance?(instance)
    }

    /// 純佈局：entries → NSMenuItem。抽成 static 是為了測試——建 `MenuBarController` 會在
    /// 開發機的選單列放一個狀態列圖示，測試只該碰一個裸的 NSMenu。
    static func populate(instanceMenu menu: NSMenu, entries: [InstanceMenuEntry],
                         target: AnyObject?, action: Selector?) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: entry.isEnabled ? action : nil,
                                  keyEquivalent: "")
            item.target = entry.isEnabled ? target : nil
            item.isEnabled = entry.isEnabled
            item.state = entry.isCurrent ? .on : .off
            item.representedObject = entry.instance
            menu.addItem(item)
        }
    }
```

- [ ] **Step 4: 跑測試確認全綠**

Run: `cd app && MIRAGE_PORT=45999 swift test --filter MenuBarInstanceMenuTests 2>&1 | tail -3`
Expected: 3 tests passed。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageShell/Lifecycle/MenuBarController.swift app/Tests/MirageShellTests/MenuBarInstanceMenuTests.swift
git commit -m "feat: 選單列加入切換模擬器子選單"
```

---

### Task 7: `AppModel` 的目前實例與切換

**Files:**
- Modify: `app/Sources/MirageShell/AppModel.swift:16`（加儲存屬性）、`:122-124`（`start()` 改讀 `currentEndpoint`）、`:461`（`startLifecycle` 加一行）
- Create: `app/Sources/MirageShell/AppModel+Instances.swift`
- Test: `app/Tests/MirageShellTests/AppModelInstanceTests.swift`（新增）

**Interfaces:**
- Consumes：`EmulatorClient.currentEndpoint`／`isRunning`／`requestedStreamSize`／`setEndpoint(_:)`（Task 4）、`EmulatorDiscovery.instances()`（Task 3）、`InstanceMenu.entries`（Task 5）、`MenuBarController.instanceEntries`／`onSwitchInstance`（Task 6）。
- Produces：
  ```swift
  extension AppModel {
      var currentEndpoint: EmulatorEndpoint            // 儲存屬性，在 AppModel.swift 本體
      func setupInstanceMenu()
      func logEndpoint(_ endpoint: EmulatorEndpoint)
      func switchInstance(to instance: EmulatorInstance) async
  }
  ```

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageShellTests/AppModelInstanceTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

/// 端點都指向沒人監聽的埠（CI 的 MIRAGE_PORT 與保留埠 1）：`switchInstance` 會真的
/// `client.start()`，連線迴圈對死埠退避重連，測試結尾一律 `client.stop()`。
@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppModelInstanceTests {
    private static func makeModel(_ tag: String) -> (AppModel, URL) {
        let (store, dir) = AppModelEditingTests.tempStore(tag)
        return (AppModel(store: store, starterBindings: { [] }), dir)
    }

    private let other = EmulatorInstance(avdName: "mirage-poc", consolePort: 5556, grpcPort: 1, pid: 2)

    @Test func currentEndpointStartsFromEnvironmentDefault() {
        let (model, dir) = Self.makeModel("endpoint-default")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.currentEndpoint == EmulatorClient.defaultEndpoint)
    }

    /// 選到目前這台：不斷線、不重連——否則每次誤點都白白斷一次串流。
    @Test func switchingToTheCurrentInstanceDoesNothing() async {
        let (model, dir) = Self.makeModel("switch-same")
        defer { try? FileManager.default.removeItem(at: dir) }
        let same = EmulatorInstance(avdName: "mirage-game", consolePort: 5554,
                                    grpcPort: EmulatorClient.defaultEndpoint.port, pid: 1)

        await model.switchInstance(to: same)

        #expect(await !model.client.isRunning)          // 沒有被 start
        #expect(model.currentEndpoint == EmulatorClient.defaultEndpoint)
    }

    /// 切換 = stop → setEndpoint → start：切完 client 在跑、端點是新的、host 不變。
    @Test func switchingChangesClientEndpointAndRestarts() async {
        let (model, dir) = Self.makeModel("switch-other")
        defer { try? FileManager.default.removeItem(at: dir) }

        await model.switchInstance(to: other)

        #expect(model.currentEndpoint.port == 1)
        #expect(model.currentEndpoint.host == EmulatorClient.defaultEndpoint.host)
        #expect(await model.client.currentEndpoint.port == 1)
        #expect(await model.client.isRunning)
        await model.client.stop()
    }

    /// 切換沿用最後一次要求的串流尺寸，不退回 540x1200。
    @Test func switchingKeepsRequestedStreamSize() async {
        let (model, dir) = Self.makeModel("switch-size")
        defer { try? FileManager.default.removeItem(at: dir) }
        await model.client.start(box: model.box, width: 900, height: 2000)

        await model.switchInstance(to: other)

        let size = await model.client.requestedStreamSize
        #expect(size.w == 900)
        #expect(size.h == 2000)
        await model.client.stop()
    }
}
```

- [ ] **Step 2: 跑測試確認編不過**

Run: `cd app && swift build --build-tests 2>&1 | grep -E 'error:' | head -3`
Expected: `value of type 'AppModel' has no member 'currentEndpoint'`／`switchInstance`。

- [ ] **Step 3: 實作**

`AppModel.swift:16`（`var connState: ConnState = .disconnected`）下面加：

```swift
    /// 目前接著的模擬器。初值來自環境（`MIRAGE_HOST`／`MIRAGE_PORT`），之後只由
    /// `switchInstance` 在 `client.setEndpoint` 成功後寫回。
    ///
    /// 這是 `client.currentEndpoint` 在 MainActor 上的鏡像，不是第二份真相：選單列的
    /// `menuNeedsUpdate` 是同步的，拿不到 actor 裡的值。寫入紀律寫在 `switchInstance`。
    var currentEndpoint: EmulatorEndpoint = EmulatorClient.defaultEndpoint
```

`AppModel.swift:122-124` 的三行：

```swift
        let endpoint = EmulatorClient.defaultEndpoint
        let auth = EmulatorDiscovery.token(port: endpoint.port) == nil ? "none" : "token"
        print("[app] endpoint=\(endpoint.host):\(endpoint.port) auth=\(auth)")
```

改成：

```swift
        let endpoint = currentEndpoint
        logEndpoint(endpoint)
```

（後面 `if let problem = endpoint.overrideProblem` 那段不動。）

`AppModel.swift:461`（`setupFullScreen()`）下面加一行：

```swift
        setupInstanceMenu()
```

新檔 `app/Sources/MirageShell/AppModel+Instances.swift`：

```swift
import AppKit
import MirageCore

/// 模擬器多開（選項 B，docs/specs/2026-09-12-multi-instance-design.md §3.3）：
/// 多台各自開機，同一時間只有一台接 Mirage。切換 = stop → setEndpoint → start，
/// 靠既有的重連機制，沒有第二條生命週期。
///
/// 獨立成 extension 檔（比照 AppModel+FullScreen.swift）：AppModel.swift 本體已滿。
extension AppModel {
    /// 綁定選單列。子選單每次展開前重掃探索檔——與「套用 profile」掃目錄同一種即時性，
    /// 模擬器起停之後不必重開 App。
    func setupInstanceMenu() {
        menuBar?.instanceEntries = { [weak self] in
            guard let self else { return [] }
            return InstanceMenu.entries(instances: EmulatorDiscovery.instances(),
                                        current: self.currentEndpoint)
        }
        menuBar?.onSwitchInstance = { [weak self] instance in
            Task { @MainActor in await self?.switchInstance(to: instance) }
        }
    }

    /// 端點無論如何都印一行——「連到另一台」的症狀（畫面不是預期那台）跟「連不上」
    /// 長得完全不一樣，沒有這行只能靠猜。`start()` 與 `switchInstance` 共用。
    func logEndpoint(_ endpoint: EmulatorEndpoint) {
        let auth = EmulatorDiscovery.token(port: endpoint.port) == nil ? "none" : "token"
        print("[app] endpoint=\(endpoint.host):\(endpoint.port) auth=\(auth)")
    }

    /// 切到另一台。只換 gRPC 埠，host 沿用目前的——`MIRAGE_HOST` 覆寫不動，探索檔本來
    /// 也只描述本機實例。同一台 → 什麼都不做，不白白斷一次線。
    ///
    /// 切換期間 `client.states` 走 `.disconnected` → `.connecting` → `.connected`，
    /// Scene 上既有的 `ConnectionBanner` 就是進度畫面（規格 §3.3：不另做畫面）。
    /// 鍵位 profile 跟著遊戲偵測走、與實例無關，這裡不碰 keymap。
    func switchInstance(to instance: EmulatorInstance) async {
        guard instance.grpcPort != currentEndpoint.port else { return }
        let target = EmulatorEndpoint(host: currentEndpoint.host, port: instance.grpcPort)
        let size = await client.requestedStreamSize
        await client.stop()
        guard await client.setEndpoint(target) else {
            // stop() 回來時迴圈已結束（EmulatorClient.stop 的說明），這條不該走到；
            // 走到了要有訊號，不能靜默留在舊那台。
            print("[app] 切換到 \(instance.avdName) 失敗：client 仍在跑，維持 \(currentEndpoint.host):\(currentEndpoint.port)")
            return
        }
        currentEndpoint = target
        logEndpoint(target)
        await client.start(box: box, width: size.w, height: size.h)
    }
}
```

- [ ] **Step 4: 跑測試確認全綠，並確認既有 Shell 測試沒動**

Run: `cd app && MIRAGE_PORT=45999 swift test --filter AppModelInstanceTests 2>&1 | tail -3`
Expected: 4 tests passed。

Run: `cd app && MIRAGE_PORT=45999 swift test --filter 'AppModel' 2>&1 | tail -3`
Expected: 全過（`AppModelEditingTests` 不受影響）。

- [ ] **Step 5: 建置 release 確認零警告**

Run: `cd app && swift build -c release 2>&1 | grep -E 'warning:|error:' | head`
Expected: 無輸出。

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MirageShell/AppModel.swift app/Sources/MirageShell/AppModel+Instances.swift app/Tests/MirageShellTests/AppModelInstanceTests.swift
git commit -m "feat: AppModel 記錄目前模擬器並可從選單列切換"
```

### Task 8: README 與活體驗證 `verify_instance_switch.sh`

**Files:**
- Create: `app/scripts/verify_instance_switch.sh`
- Modify: `app/README.md`（檔尾加一節）

**Interfaces:**
- Consumes：`emu.sh -n <名稱> start|stop`（Task 2）、`emu_resolve`（Task 1）、`verify_keyboard.sh` 的 `MIRAGE_ADB_SERIAL`／`MIRAGE_PORT`（`verify_keyboard.sh:23-24`）、`verify_common.sh` 的 `require_adb`／`assert_ok`／`assert_equals`（`:18,61,76`）、`load_sentinel.sh` 的 `disk_preflight`（`:60`）。
- Produces：`./scripts/verify_instance_switch.sh`，退出碼 0 = 規格 §3.5 的切換判準全過。環境變數 `MIRAGE_FIRST`（預設 `mirage-game`）、`MIRAGE_SECOND`（預設 `mirage-poc`）、`MIRAGE_KEEP=1` 結束後不停第二台。

**這支腳本驗的是什麼、沒驗什麼**：它驗「兩台各自開機、Mirage 的 client 逐台連 5554→5556→5554 都能把鍵送進 guest、另一台全程開著」——規格 §3.5 第三、四條，判定在 guest 的 `getevent`。它**沒有**驅動選單列的子選單：那條路徑由 Task 5 到 Task 7 的單元測試涵蓋，GUI 端到端見 Step 6 的人工步驟。

- [ ] **Step 1: 寫腳本**

`app/scripts/verify_instance_switch.sh`：

```bash
#!/usr/bin/env bash
# 模擬器多開切換的活體驗證（docs/specs/2026-09-12-multi-instance-design.md §3.5）。
#
# 兩台各自用 `emu.sh -n` 啟動，依序對第一台、第二台、第一台跑 verify_keyboard.sh 的判定
# （儀器是 guest 的 getevent，不是 Swift 測試的綠燈），每一段之後確認**另一台**仍然
# `sys.boot_completed = 1`——切換的定義是「舊的那台維持開機但不串流」，不是被關掉。
#
# 用法：./scripts/verify_instance_switch.sh
#   MIRAGE_FIRST／MIRAGE_SECOND：兩台的實例名稱（lib/emu_instances.sh 的表；預設 mirage-game／mirage-poc）
#   MIRAGE_KEEP=1：結束後不停第二台
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/verify_common.sh"
source "${SCRIPT_DIR}/lib/emu_instances.sh"
source "${SCRIPT_DIR}/lib/load_sentinel.sh"

FIRST="${MIRAGE_FIRST:-mirage-game}"
SECOND="${MIRAGE_SECOND:-mirage-poc}"
TABLE="${MIRAGE_INSTANCES:-$EMU_DEFAULT_INSTANCES}"

require_adb
disk_preflight "$SCRIPT_DIR" || exit 1
if [ "$FIRST" = "$SECOND" ]; then
    echo "❌ 兩台必須是不同的實例（都給了 ${FIRST}）"; exit 1
fi
FIRST_T=$(emu_resolve "$FIRST" "$TABLE") || exit 1
SECOND_T=$(emu_resolve "$SECOND" "$TABLE") || exit 1
read -r FIRST_AVD FIRST_PORT FIRST_GRPC <<< "$FIRST_T"
read -r SECOND_AVD SECOND_PORT SECOND_GRPC <<< "$SECOND_T"
AVD_DIR="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
for avd in "$FIRST_AVD" "$SECOND_AVD"; do
    if [ ! -f "${AVD_DIR}/${avd}.ini" ]; then
        echo "❌ 找不到 AVD ${avd}（${AVD_DIR}/${avd}.ini）。用 tools/provision 建：cd tools/provision && python3 provision.py --apply"
        exit 1
    fi
done
echo "✅ 兩台：${FIRST}（${FIRST_PORT}／${FIRST_GRPC}）與 ${SECOND}（${SECOND_PORT}／${SECOND_GRPC}）"

echo ""
echo "=== 啟動兩台 ==="
"${SCRIPT_DIR}/emu.sh" -n "$FIRST" start
assert_ok "第一台 ${FIRST} 啟動" "$?"
"${SCRIPT_DIR}/emu.sh" -n "$SECOND" start
assert_ok "第二台 ${SECOND} 啟動" "$?"
"${SCRIPT_DIR}/emu.sh" status

# 同一個 AVD 不能開第二台（規格 §3.1）：表只給一台、放在別的埠，start 必須擋下而不是去起。
echo ""
echo "=== AVD 衝突要被擋 ==="
MIRAGE_INSTANCES="${FIRST_AVD}:5558:8558" "${SCRIPT_DIR}/emu.sh" -n "$FIRST_AVD" start > /dev/null 2>&1
rc=$?
assert_equals "同 AVD 在別的埠 start 的退出碼" "$rc" "1"

# 對指定的一台跑鍵盤判定，再確認另一台還開著。
# verify_keyboard.sh 自己 cd 到 app/，所以用絕對路徑呼叫。
check_target() {
    local label="$1" port="$2" grpc="$3" other_label="$4" other_port="$5" booted
    echo ""
    echo "=== 切到 ${label}（emulator-${port}，gRPC ${grpc}）==="
    MIRAGE_ADB_SERIAL="emulator-${port}" MIRAGE_PORT="$grpc" "${SCRIPT_DIR}/verify_keyboard.sh"
    assert_ok "${label} 的鍵盤判定" "$?"
    booted=$("$ADB" -s "emulator-${other_port}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    assert_equals "另一台 ${other_label} 仍在開機狀態（sys.boot_completed）" "$booted" "1"
}

check_target "$FIRST"  "$FIRST_PORT"  "$FIRST_GRPC"  "$SECOND" "$SECOND_PORT"
check_target "$SECOND" "$SECOND_PORT" "$SECOND_GRPC" "$FIRST"  "$FIRST_PORT"
check_target "$FIRST"  "$FIRST_PORT"  "$FIRST_GRPC"  "$SECOND" "$SECOND_PORT"

echo ""
if [ "${MIRAGE_KEEP:-0}" != "1" ]; then
    echo "=== 只停第二台，第一台要還在 ==="
    "${SCRIPT_DIR}/emu.sh" -n "$SECOND" stop
    assert_ok "停第二台" "$?"
    "${SCRIPT_DIR}/emu.sh" -n "$FIRST" status > /dev/null 2>&1
    assert_equals "第一台在停第二台之後仍在執行（status 退出碼）" "$?" "0"
fi

echo ""
echo "全部通過：${FIRST} → ${SECOND} → ${FIRST} 三段鍵盤判定皆送達，另一台全程開機"
```

- [ ] **Step 2: 語法、閘門 4 lint、執行權限**

Run: `chmod +x app/scripts/verify_instance_switch.sh && bash -n app/scripts/verify_instance_switch.sh && echo syntax-ok`
Expected: `syntax-ok`。

Run: Task 1 Step 7 的 python，檔案清單換成 `["scripts/verify_instance_switch.sh"]`。
Expected: 只印 `lint done`。（`source` 都在任何 `cd` 之前，第二段 lint 也不會命中。）

- [ ] **Step 3: 跑活體驗證**

前置：主機安靜（`host-background-work-blocks-measurement`：外來 CPU 先看一眼 `top -l 1 | head -12`）、磁碟 ≥ 5 GiB、兩個 AVD 都在（`~/Library/Android/sdk/emulator/emulator -list-avds` 要列出 `mirage-game` 與 `mirage-poc`）。

Run: `cd app && ./scripts/verify_instance_switch.sh 2>&1 | tee /tmp/verify_instance_switch.log; echo "rc=${PIPESTATUS[0]}"`（zsh 下改用 `bash -c '…'` 包起來，見 `shell-exit-code-traps`）。
Expected：
- `✅ 第一台 mirage-game 啟動`、`✅ 第二台 mirage-poc 啟動`，`status` 列出兩行 `執行中：emulator-5554…`／`emulator-5556…`，各自 `gRPC 8554 綁定：127.0.0.1:8554`／`8556`。
- `✅ 同 AVD 在別的埠 start 的退出碼：1`。
- 三段各印 `verify_keyboard.sh` 的六個 ✅（`KEY_A`…`KEY_APPSELECT`）與 `✅ 另一台 … sys.boot_completed：1`。
- `✅ 停第二台`、`✅ 第一台在停第二台之後仍在執行…`、`rc=0`。

跑兩次（`measurement-variance-exceeds-threshold`：一次是假設不是結論）。若第二台開機超過 90 秒（`emu.sh` 的上限），那是主機負載，不是本功能——先看 `guest-fps-collapses-silently` 列的兩個原因。

- [ ] **Step 4: README 加一節**

`app/README.md` 檔尾加：

```markdown
## 模擬器多開（可切換）

多台模擬器各自存在、各自開機，Mirage 同一時間只接一台；切換 = `EmulatorClient.stop()` → 換端點 →
`start()`，走既有的重連機制。「兩台同時可玩」在 M1 16GB 上量過不成立（`RESULTS-multi-instance.md`），
所以沒有兩個視窗、也不同時串流兩台。設計：`../docs/specs/2026-09-12-multi-instance-design.md`。

- **啟停**：`./scripts/emu.sh -n <名稱> start|stop|status`。名稱就是 AVD 名稱，埠在
  `scripts/lib/emu_instances.sh` 的實例表（預設 `mirage-game:5554:8554 mirage-poc:5556:8556`，
  `MIRAGE_INSTANCES` 可整份覆寫）。不帶 `-n` 與以前完全相同。`status` 列出所有執行中的實例與
  各自的 gRPC 綁定位址；`stop` 只停指定那台。每台要各自一個 AVD——同一個 AVD 開第二台會被
  `start` 直接擋下（AVD 用 `tools/provision` 加）。
- **切換**：選單列 🪞 →「切換模擬器 ▸」，列出探索檔（`~/Library/Caches/TemporaryItems/avd/running/pid_*.ini`）
  裡活著的實例，目前那台打勾；沒有其他實例時只有一個停用項「沒有其他模擬器」。切換期間畫面上
  是既有的連線橫幅（未連線 → 連線中…）。只換 gRPC 埠，`MIRAGE_HOST` 覆寫不動；`MIRAGE_PORT`
  只決定啟動時接哪一台。鍵位 profile 跟著遊戲偵測走，與實例無關。
- **活體驗證**：`./scripts/verify_instance_switch.sh`——兩台各自 `emu.sh -n` 啟動，對 5554→5556→5554
  依序跑 `verify_keyboard.sh` 的 `getevent` 判定，每段確認另一台 `sys.boot_completed` 仍為 1。
  純函式的自我測試在 `scripts/lib/emu_selftest.sh`（`ci.sh` 閘門 7）。
```

- [ ] **Step 5: 跑整支 `ci.sh`**

Run: `cd app && ./scripts/ci.sh 2>&1 | tail -15; echo "rc=$?"`（bash 下 `$?` 是 tail 的，要看 `${PIPESTATUS[0]}`；或直接不接管線）。
Expected: 十道閘門全 ✅，最後一行含 `十支共用函式庫自我測試（…／emu_instances）皆綠`，退出碼 0。

- [ ] **Step 6: 人工端到端（未自動化，做完在 commit 訊息附一行結果）**

這一段沒有腳本，理由與 README「殘餘涵蓋面」第 3 項相同：選單項的 `@objc` 動作需要 GUI。做法：

1. 兩台都起著（Step 3 加 `MIRAGE_KEEP=1`）。
2. `./scripts/package_app.sh` 組 `.app`，用 `open` 開（不要從 shell 直接跑 executable），`MIRAGE_CONN_LOG=1`。
3. 選單列 🪞 →「切換模擬器 ▸」：兩列、`mirage-game（console 5554／gRPC 8554）` 打勾。
4. 點 `mirage-poc…`：橫幅出現「未連線」→「連線中…」→消失；console 印 `[app] endpoint=localhost:8556 auth=token`；畫面變成第二台的桌面。再開子選單，勾在 `mirage-poc`。
5. 在鏡像視窗按幾個鍵，`adb -s emulator-5556 shell getevent -l` 看到 `KEY_*`；`adb -s emulator-5554 shell getprop sys.boot_completed` 仍是 1。
6. 切回 `mirage-game`，重複第 5 點對調 serial。
7. 停掉第二台（`./scripts/emu.sh -n mirage-poc stop`），再開子選單：只剩停用的「沒有其他模擬器」。

- [ ] **Step 7: Commit**

```bash
git add app/scripts/verify_instance_switch.sh app/README.md
git commit -m "test: 模擬器多開切換的活體驗證腳本與 README"
```

---

## Self-Review

**1. Spec coverage（§3 逐條對 task）**

| 規格 | Task |
|---|---|
| §3.1 三元組、每台一個 AVD、同 AVD 兩次報錯 | Task 1（`emu_table_check`、`emu_avd_conflict`）、Task 2（start 擋）、Task 8（活體驗證衝突退出碼） |
| §3.1 token 依 gRPC 埠找、不用改 | 不改；Task 7 的 `logEndpoint` 仍用 `EmulatorDiscovery.token(port:)` |
| §3.2 `-n`、預設 5554／8554 | Task 1、Task 2 |
| §3.2 `running()` 比對 console 埠 | Task 1（`emu_is_running`）、Task 2 |
| §3.2 `status` 列全部＋gRPC 綁定 | Task 1（`emu_running_instances`）、Task 2 |
| §3.2 `stop` 只停指定實例 | Task 2（`adb -s $SERIAL emu kill` 配新的 `running()`） |
| §3.3 `AppModel` 目前實例、預設值與環境覆寫維持 | Task 7（`currentEndpoint = EmulatorClient.defaultEndpoint`） |
| §3.3 子選單列活著的實例、「列出全部」純函式 | Task 3（`listInstances`）、Task 5、Task 6 |
| §3.3 `stop → 換端點 → start` | Task 4（`setEndpoint`）、Task 7（`switchInstance`） |
| §3.3 切換期間既有橫幅 | Task 7（不改 `ConnectionBanner`，狀態流自然經過 `.disconnected`→`.connecting`） |
| §3.3 keymap 不改 | 無 task 動 keymap |
| §3.4 不做的三項 | 無 task 做 |
| §3.5 `emu.sh` 兩台各自 start／status／stop、自我測試進閘門 7 | Task 1（閘門 7）、Task 8 |
| §3.5 `listInstances` 單元測試用真實格式 | Task 3 |
| §3.5 5554→5556→5554 各過一次 `verify_keyboard.sh`、getevent 判定 | Task 8 |
| §3.5 另一台 `sys.boot_completed` 為 1 | Task 8 |

缺口：無。規格沒要求但本計畫加的兩項——`stop()` 等舊迴圈（設計決定 2）、切換沿用串流尺寸（Task 4 `requestedStreamSize`）——各有理由寫在該 task。

**2. Placeholder scan**：全文搜過 `TBD`／`TODO`／`稍後`／`參考 Task`／「適當的錯誤處理」——無。每個程式碼步驟都有完整程式碼；Task 8 Step 6 是明確標示的人工步驟，不是佔位。

**3. Type consistency**：
- `EmulatorInstance(avdName:consolePort:grpcPort:pid:)`：Task 3 定義，Task 5／6／7 測試同一組標籤。
- `EmulatorDiscovery.instances(files:isAlive:)`／`listInstances(directory:isAlive:readFiles:)`／`instances()`：Task 3 定義，Task 7 用 `instances()`。
- `EmulatorClient.currentEndpoint`／`isRunning`／`requestedStreamSize`／`setEndpoint(_:) -> Bool`：Task 4 定義，Task 7 全部用到且名稱一致。
- `InstanceMenuEntry(title:instance:isCurrent:)`、`InstanceMenu.entries(instances:current:)`、`InstanceMenu.placeholderTitle`：Task 5 定義，Task 6、7 一致。
- `MenuBarController.instanceEntries`／`onSwitchInstance`／`populate(instanceMenu:entries:target:action:)`：Task 6 定義，Task 7 綁前兩個。
- `AppModel.currentEndpoint`／`switchInstance(to:)`／`setupInstanceMenu()`／`logEndpoint(_:)`：Task 7 定義並在 `start()`／`startLifecycle()` 呼叫。
- bash：`emu_resolve`／`emu_table_check`／`emu_running_instances`／`emu_is_running`／`emu_avd_conflict`／`EMU_DEFAULT_INSTANCES`：Task 1 定義，Task 2、8 的呼叫名稱與參數順序一致（`emu_is_running "<ps>" <port>`、`emu_avd_conflict "<ps>" <avd> <port>`）。
- `verify_keyboard.sh` 的覆寫變數 `MIRAGE_ADB_SERIAL`／`MIRAGE_PORT`（`:23-24`）：Task 8 逐字相同。

## 沒把握的地方（實作時先驗）

1. `#expect(await !client.isRunning)` 這種 `await` 後接前綴 `!` 的寫法（Task 4、7）——若編譯器不收，改成 `let running = await client.isRunning; #expect(!running)`，語意不變。
2. `stop()` 加 `await loopTask?.value` 後，既有測試裡若有 probe／sleeper 假件不理會取消，會卡到 `.timeLimit`；Task 4 Step 4 已寫明修假件不修 await。
3. `NSMenuItem.representedObject` 放 Swift struct（`EmulatorInstance`）再 `as? EmulatorInstance` 取回：`Any?` 橋接應可行（`forceMenu` 放的是 `String`，同一個機制）；Task 6 的測試第一條就驗它。
4. `emulator -port` 的合法範圍 5554–5682 偶數（`emu_validate_triplet`）來自 emulator 文件，未在本機逐一試；若某版本放寬，只需改那兩個數字與對應的自我測試。
