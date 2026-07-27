# [FIXED UPSTREAM] Issue Tracker — Emulator MMAP ImageTransport broken on macOS

> **⚠️ 2026-07-27 後續更正**：本文件下方「明確帶尺寸即可繞過，現有 emulator 版本就能走
> MMAP 串流」一句，**只對 Python（grpcio）client 成立，對產品實際使用的 Swift
> （grpc-swift）client 不成立**——`MmapStreamTransport` 活體驗證發現串流會凍結。原文
> **保留不刪**（見下方相關段落），更正說明見文末「後續更正（2026-07-27）」小節與
> `app/RESULTS-mmap.md`。

**已提交（2026-07-23）**: https://issuetracker.google.com/issues/537802959
**提交當日狀態**: Assigned（Google 工程師）、P3/S3、2 hotlists。實際提交於 component Android Studio（192708，Emulator 子元件不開放外部直接建立），內文含 triage 轉派註記。

## 上游結案（2026-07-25 Marked as fixed）

Google 工程師接受並定位根因，原文：

> At the beginning of streamScreenshot, the server attempted to pre-borrow the shared
> memory region using `request->width() * request->height()`, which can be **0 when
> requesting the device width and height**, poisoning the cache.

並補充：**qemu-next 不存在此問題**。

### ⚠️ 對 Mirage 的關鍵發現：不需要等新版，我們也從來不該受影響

本報告的 repro（下方 Steps to reproduce 第 3 點）建構的 `ImageFormat` **不帶 width/height**
——即請求裝置原生尺寸，兩者為 0，正好踩中上述根因。

**2026-07-27 對照實驗**（`phase0/harness/probe_mmap_explicit.py`，在**同一個 canary
37.2.1.0**、即早於上游修正的 build 上執行）：

| 請求形狀 | 幀數 | 相異雜湊 | 緩衝區內容 |
|---|---|---|---|
| 不帶 width/height（原 repro） | 5 | 1 | 全零 |
| **明確帶 width/height** | 5 | **5** | **真實像素** |

→ **明確帶尺寸即可繞過，現有 emulator 版本就能走 MMAP 串流。**

而 **Mirage 的 `GrpcStreamTransport.frames(width:height:)` 一直都帶明確尺寸**
（`format.width = UInt32(width)`，由 `setStreamSize` 驅動）。也就是說：Phase-0 用了一個
Mirage 實際上不會送的請求形狀去探測，據此判定「MMAP 串流在 macOS 壞掉」，並為此建了
`UnaryMmapTransport` workaround——**那個 workaround 是為一個我們不會踩到的 bug 而建的**。

**教訓**：探測外部 API 的可用性時，請求形狀必須與產品實際會送的形狀一致；否則結論只對
探測腳本成立，不對產品成立。

## 後續更正（2026-07-27，Task 8/9 活體驗證）

**上面這句教訓本身還不夠——它只解決了「請求形狀」這一個變數，遺漏了另一個更根本的變數：
用哪個 client 實作去驗證。**

上面「明確帶尺寸即可繞過，現有 emulator 版本就能走 MMAP 串流」的結論，全程只用 Python
（grpcio）驗證過。`docs/specs/2026-07-27-mmap-stream-transport-design.md` §1 據此判定
「上游 bug 已修，且實測確認現有 emulator 版本即可繞過」，於是啟動了 `MmapStreamTransport`
的實作（Task 1–7，基礎建設本身審查全部乾淨）。

但 Task 8 活體驗證改用**產品實際使用的** grpc-swift client 測試同一個 `streamScreenshot`
+ MMAP 呼叫時，發現完全不同的行為：**`MmapStreamTransport` 在同一台、同一時刻、同尺寸
（540×1200）的 emulator 37.2.1.0 上只完成一次真實寫入，之後映射區凍結不再更新**——3 幀
（甚至拉到 30 幀、跨 480ms）內容逐位元組相同。同一時刻用 Python 對照腳本重跑，仍穩定拿到
5 個相異幀。三輪排查推翻了 8 個以上假設（protobuf 編碼、暖機、執行緒數、檔案建立語意、
API 選擇、讀取端快取、畫面尺寸、guest 動畫是否在跑），根因收斂到「emulator 對 grpc-swift
連線與 grpcio 連線行為不同」，但**確切機制未鎖定**。完整排查過程見
`.superpowers/sdd/2026-07-27-mmap-stream-transport/mmap-freeze-investigation.md` 與
`task-8-report.md`；裁決與驗收結果見 `app/RESULTS-mmap.md`。

**更正**：「實測確認現有 emulator 版本即可繞過」這句話，**應理解為「只對 Python client
成立」**，不能推論到「產品的 Swift client 也能走 MMAP 串流」。上面的原文與量化收益數字
（qemu CPU −8~9%、client CPU −91% 等）本身沒有錯——它們如實描述了 Python 實作量到的
主機能力上限——錯的是把這個結論**不經產品 client 驗證就套用到 Mirage 產品本身**，並以此
作為「現在就做 MMAP 串流實作」的立論基礎之一。

**最終處置**（使用者裁決，見 `app/RESULTS-mmap.md`）：display transport 預設改回 raw
RGBA，MMAP 改為 `MIRAGE_TRANSPORT=mmap` 環境變數主動選擇加入，且仍需版本 ≥37（獨立安全
互鎖，與此凍結問題無關，36.x 收到 MMAP 請求會 SIGSEGV）。Task 1–7 的基礎建設（純函式、
`MmapBuffer`、`FallbackTransport`、`HealthResult` 帶版本等）保留，供未來在含上游修正的
emulator build 上重新驗證時直接沿用。

**再次教訓（本次更正的核心）**：探測外部 API 的可用性時，不只請求形狀要與產品一致，**驗證
用的 client 實作本身也必須是產品實際會用的那一個**（或至少要交叉驗證兩者行為一致）；用
「行為上看起來等價」的替代實作（哪怕是同一份 proto、同一種呼叫慣例）驗證出的結論，只對
那個替代實作成立，不能自動套用到產品——這正是本文件第一次教訓沒有寫全、被 Task 8 活體
驗證抓出來的部分。

### 收益量化（2026-07-27，`phase0/harness/bench_mmap_vs_rgba.py`）

> **第一版量測有瑕疵，已作廢**：MMAP 組只在前 5 幀讀取映射緩衝區，之後完全不消費影像
> 資料，量出灌水的「94% CPU 降幅」與「fps 提升」。下表為修正後的公平比較——三組都對
> **每一幀**做等量的資料消費工作。

在 Mirage 的實際操作點 **900×2000**（`StreamSize.maxPixels` 上限下的直向全螢幕尺寸）
各跑 10 秒、連測三次。因 fps 本身在漂（機器負載逐次上升），**每幀 CPU** 才是可比單位：

| 指標 | rgba | mmap-copy | mmap-touch |
|---|---|---|---|
| client CPU / 幀 | **7.8 / 8.0 / 8.1 ms** | **0.68 / 0.71 / 0.74 ms** | 0.46 / 0.52 / 0.50 ms |
| 經 gRPC 的位元組 | 272 / 246 / 222 MiB/s | **0** | **0** |
| qemu CPU（10 秒窗口） | 19.9 / 19.6 / 19.0 s | 18.3 / 17.9 / 17.3 s | 18.3 / 17.8 / 17.5 s |
| fps | 39.7 / 35.9 / 32.3 | 43.8 / 36.6 / 31.0 | 41.5 / 34.8 / 32.1 |

（`mmap-copy` = 每幀完整複製映射區，對應現行 `Frame.rgba: Data` 設計；
`mmap-touch` = 只觸碰不複製，對應「渲染端直接從映射區上傳」的零拷貝上限。）

**成立的結論**：

- 消滅 protobuf 讓 client 每幀 CPU 從 ~8.0 ms 降到 ~0.7 ms（**−91%**），且 mmap 組每幀
  都做了完整 7.2 MB 複製，是公平比較。以 60fps 換算，client 每秒省下約 0.44 個核心。
- qemu 端穩定省 **8–9%**。
- **零拷貝不划算**：`mmap-copy` 與 `mmap-touch` 只差 0.2 ms/幀。memcpy 幾乎免費，貴的是
  protobuf。**保持 `Frame.rgba: Data` 現狀即可，不需要為零拷貝改設計**——這讓實作範圍小很多。

**不成立、已撤回的結論**：第一版曾據灌水數字宣稱「fps 51.5→55.9，可能是驗收線 7 過與不過
的差別」。修正後三次分別是 +4.1 / +0.7 / −1.3，在雜訊範圍內，**fps 是平手**。優先做 MMAP
的理由只建立在 CPU 與頻寬上，不建立在 fps 上。

**限制（誠實記錄）**：client CPU 以 **Python** client 量測，Swift／grpc-swift 的絕對值必然
不同；但「消滅 220–272 MiB/s 的 protobuf payload」與「qemu 端 −8~9%」兩項與 client 語言無關。

**後續**（尚未執行，需各自決策）：
1. ~~量化收益~~ → 已完成，見上表
2. 在 `MirageCore` 實作 streaming MMAP transport（`GrpcStreamTransport` 已帶明確尺寸，
   只需加上 `ImageTransport{MMAP, handle}` 與 client 端的緩衝區生命週期管理）
3. `UnaryMmapTransport`（108 行、版本閘、從未接上 App 執行期）屆時可正式退場——它同時是
   MirageCore 覆蓋率的長期拖累（見架構債記錄）

---

---

**Title:** macOS (Apple Silicon): gRPC streamScreenshot with ImageTransport MMAP crashes emulator engine (36.6.11.0) / silently never writes frames (37.2.1.0 canary)

**Component:** Android Studio > Emulator

**Build/version info:**
- Host: MacBook Air (M1, 16 GB), macOS 26.3.1 (arm64)
- Emulator (stable): 36.6.11.0 (build_id 15507667)
- Emulator (canary): 37.2.1.0 (build_id 15875889)
- AVD: pixel_7, system-images;android-35;default;arm64-v8a, cold boot
- Launch: `emulator @avd -no-window -no-audio -no-boot-anim -gpu host -grpc 8554`

**Steps to reproduce:**
1. Boot the AVD headless with gRPC enabled (flags above), wait for sys.boot_completed=1.
2. Create a client-owned frame buffer file sized width*height*4 (e.g. 1080*2400*4 = 10,368,000 bytes).
3. Call `EmulatorController.streamScreenshot` with:
   `ImageFormat{ format: RGBA8888, transport: ImageTransport{ channel: MMAP, handle: "file:///abs/path/to/buffer.bin" } }`
4. Observe.

**Observed — stable 36.6.11.0:** the qemu engine process terminates immediately
(SIGSEGV, exit 139; crashpad handler output observed in the engine log). Deterministic: 2/2 with the
`file:///` handle across independent cold boots; a POSIX-shm-style handle
(`/name`) also kills the engine (SIGABRT, exit 134). Client sees
`UNAVAILABLE: Stream removed (Socket closed)` with zero frames delivered.

**Observed — canary 37.2.1.0:** no crash. The stream delivers Image messages
at a plausible frame cadence with `image` payload EMPTY (0 bytes, as expected
for MMAP transport) and correct `format.width/height` (1080x2400). However the
client's buffer is never written: content stays all-zero across frames
(identical md5 per frame), the file's inode never changes (rules out
recreate-behind semantics), and no PSXSHM objects appear. (`lsof` during an
active stream shows no retained fd for the handle either, though an
open-mmap-close pattern would also look this way — the decisive isolation is
the unary-vs-stream experiment below.) Tried three handle variants (long `file:///` temp
path, short `file:///tmp/x.bin`, bare shm-style name): no data written in any case — all-zero buffer for the file paths; for the bare shm name, no shm object was even created (inference:
none was rejected — notifications flowed for all three). So on macOS the MMAP
transport's host write side appears to be a silent no-op while the
notification side works.

**Expected:** either (a) frames are written into the client-provided
mmap/shm handle as documented in emulator_controller.proto (the `handle` field's comment in ImageTransport, emulator_controller.proto: "The client sets and owns this handle. It can be either a shm region, or a mmap."), or (b) the request is rejected cleanly with
INVALID_ARGUMENT/UNIMPLEMENTED on platforms where MMAP transport is
unsupported — never an engine crash, never empty notifications with no data.

**Impact:** raw RGBA streaming pushes ~10 MiB/frame through protobuf
serialization (measured ~55 fps at native 1080x2400 on an idle M1 host,
~546 MiB/s per stream). MMAP is the built-in way to avoid that per-frame
serialization cost — it matters for client/host CPU efficiency,
multi-instance setups, and >60 fps headroom. With streaming MMAP broken,
the only shared-memory option on macOS is polling unary getScreenshot
(works, ~52 calls/s measured), which loses the change-driven delivery that
streamScreenshot provides.

**Root-cause isolation (unary works, streaming does not):** on the same
canary build and host, a *unary* `getScreenshot` call with the identical
`ImageTransport{MMAP, file://...}` request **works correctly**: the reply has
empty payload, `transport.channel == MMAP`, and the client's file receives
real pixel data (verified nonzero + changing md5). Sustained unary polling
delivers ~52 calls/s (p50 15.3 ms per call) with fresh content. So the
shared-memory plumbing (`SharedMemoryLibrary` / `aemu::base::SharedMemory`
file:// path) is functional on macOS — the defect is isolated to
**`streamScreenshot`'s per-frame writer path**, which borrows the shm region
but never writes frames into it (and still emits empty-payload notifications).
Reading `EmulatorService.cpp` (emu-master-dev,
services/emulator-controller/server/src/android/emulation/control/): the
unary path guards with `shm->isOpen() && shm->isMapped()` before redirecting
pixels, while the streaming path's borrow result does not appear to feed the
per-frame write, and `SharedMemoryLibrary::borrow` has assert-only error
handling — in release builds a failed open would also be silent. A fix on the
streaming path mirroring the unary logic (write into the mapped region when
available, else fall back to payload bytes or fail with INVALID_ARGUMENT)
would likely resolve this.

**Happy to provide:** crashpad dumps, full client repro script (Python,
~60 lines, grpcio only), lsof captures, measurement logs.
