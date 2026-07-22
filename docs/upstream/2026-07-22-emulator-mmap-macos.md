# [Draft] Issue Tracker submission — Emulator MMAP ImageTransport broken on macOS

**提交網址**: https://issuetracker.google.com/issues/new?component=192727 (Android Studio > Emulator)
**提交前確認**: 版本號與重現輸出對照 phase0/RESULTS-0b.md 附錄；以下為貼上用全文。

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
(SIGSEGV, exit 139; crashpad handler fires). Deterministic: 2/2 with the
`file:///` handle across independent cold boots; a POSIX-shm-style handle
(`/name`) also kills the engine (SIGABRT, exit 134). Client sees
`UNAVAILABLE: Stream removed (Socket closed)` with zero frames delivered.

**Observed — canary 37.2.1.0:** no crash. The stream delivers Image messages
at a plausible frame cadence with `image` payload EMPTY (0 bytes, as expected
for MMAP transport) and correct `format.width/height` (1080x2400). However the
client's buffer is never written: content stays all-zero across frames
(identical md5 per frame), the file's inode never changes (rules out
recreate-behind semantics), and — decisively — `lsof -p <qemu_pid>` during an
active MMAP stream shows the engine has NOT opened the handle path at all, and
no PSXSHM objects exist. Tried three handle variants (long `file:///` temp
path, short `file:///tmp/x.bin`, bare shm-style name): same result (inference:
none was rejected — notifications flowed for all three). So on macOS the MMAP
transport's host write side appears to be a silent no-op while the
notification side works.

**Expected:** either (a) frames are written into the client-provided
mmap/shm handle as documented in emulator_controller.proto (ImageTransport:
"Write images to the a file/shared memory handle. The client sets and owns
this handle."), or (b) the request is rejected cleanly with
INVALID_ARGUMENT/UNIMPLEMENTED on platforms where MMAP transport is
unsupported — never an engine crash, never empty notifications with no data.

**Impact:** MMAP is the only built-in path that avoids the ~10 MiB/frame
protobuf serialization cost of raw RGBA streaming, which caps
streamScreenshot at roughly 30 fps at native resolution on Apple Silicon
hosts (measured; gRPC transport, continuous screen updates). With MMAP broken
there is no built-in 60 fps display-out path on macOS.

**Happy to provide:** crashpad dumps, full client repro script (Python,
~60 lines, grpcio only), lsof captures, measurement logs.
