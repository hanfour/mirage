# [SUBMITTED] Issue Tracker — Emulator MMAP ImageTransport broken on macOS

**已提交（2026-07-23）**: https://issuetracker.google.com/issues/537802959
**提交當日狀態**: Assigned（Google 工程師）、P3/S3、2 hotlists。實際提交於 component Android Studio（192708，Emulator 子元件不開放外部直接建立），內文含 triage 轉派註記。
**追蹤**: 上游若要求 crashpad dumps / repro script，素材見 phase0/ 與 .superpowers 診斷紀錄。

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
