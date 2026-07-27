# [FIXED UPSTREAM] Issue Tracker — Emulator MMAP ImageTransport broken on macOS

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

### 收益量化（2026-07-27，`phase0/harness/bench_mmap_vs_rgba.py`）

在 Mirage 的實際操作點 **900×2000**（`StreamSize.maxPixels` 上限下的直向全螢幕尺寸）
各跑 10 秒，連測三次：

| 指標 | raw RGBA | MMAP | 變化 |
|---|---|---|---|
| 經 gRPC 的位元組 | 313–354 MiB/s | **0** | 完全消滅 |
| client CPU（10 秒窗口） | 3.65–3.75 s | **0.19–0.22 s** | **−94～95%**（三次皆然） |
| qemu CPU（10 秒窗口） | 20.65–20.74 s | 18.69–18.89 s | −約 9% |
| fps | 45.6 / 48.9 / 51.5 | 46.6 / 55.9 / 55.9 | MMAP 三次皆 ≥ |

**限制（誠實記錄）**：client CPU 以 **Python** client 量測，Swift／grpc-swift 的絕對值必然
不同；但「消滅 313–354 MiB/s 的 protobuf payload」與「qemu 端 −9%」兩項與 client 語言無關。
fps 的優勢真實但較小且有雜訊（第三次兩條路徑同時下降，研判為主機競用）。

**與驗收線的關係**：母計畫驗收線 7 要求 App 合成層 fps ≥ 55。MMAP 在三次中有兩次量到
55.9，raw RGBA 則從未達 55——這可能正好是那條線過與不過的差別（但該驗收線量的是 App
合成層，本基準量的是傳輸層，兩者不可直接等同）。

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
