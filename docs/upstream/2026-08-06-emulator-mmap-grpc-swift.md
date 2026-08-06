# Issue Tracker — streamScreenshot MMAP 只對 grpc-swift client 停止更新

**已提交（2026-08-06）**: https://issuetracker.google.com/issues/543078932

**提交當日狀態**: _未記錄_——提交是由人在 Issue Tracker 上完成的，這裡沒有留下當日的
component／優先序／assignee。比照 537802959 那份的慣例，這一列該補上，下次看 issue
時順手填。**刻意留白而不是猜**：這個 repo 的教訓是查無出處的數字會被抓，狀態欄位同理。

**與 537802959 的關係**：那一則已於 37.2.3 修正，**但對本問題無效**——我們用可靠的
400 幀窗口在 37.2.3 上重測，Swift 15–18/400、Python 379–396/400，與 37.2.1 無差異。
上游修的是 `request->width() * request->height()` 為 0 的 pre-borrow 毒化 cache，而
Mirage 從一開始就帶明確尺寸、踩不到那個 bug。**這是不同的問題，建議開新 issue 而不是
重開舊的。**

完整調查記錄見 `app/RESULTS-mmap.md`（2026-08-05 三節）。

---

## 提交的 issue 內文（英文）

### Title

`streamScreenshot` with `ImageTransport.MMAP` stops updating the shared region — but only when the request comes from a grpc-swift client

### Summary

When a client requests `streamScreenshot` with `ImageTransport.MMAP`, the emulator keeps
delivering notifications at the expected rate and `Image.seq` increments monotonically —
but **the contents of the shared memory region never change**, if and only if the request
was issued by a **grpc-swift** client. An otherwise identical request issued by a
**grpcio (Python)** client, targeting **the same file, in the same process, at the same
moment**, works correctly.

This is **not** b/537802959 (fixed in 37.2.3). We verified 37.2.3 with a reliable
sampling window: no change. Our request has always carried explicit non-zero
`width`/`height`, so it never hit that pre-borrow path.

### Environment

- Host: macOS 26.3.1 on Apple Silicon (Darwin 25.3.0), 8 cores, APFS
- Emulator: reproduced identically on **37.1.11** (stable, build 15917651),
  **37.2.1** (build 15875889) and **37.2.3** (build 15982021)
- AVD: Pixel-7-like, `android-35;default;arm64-v8a`, 1080×2400, `-gpu host`
- Clients: **grpc-swift 1.27.5** (fails) vs **grpcio 1.82/1.83** (works)
- Request: `ImageFormat{ format: RGBA8888, width: 540, height: 1200,
  transport: { channel: MMAP, handle: "file:///var/folders/.../foo.bin" } }`
- The client creates the file itself: `open(O_RDWR|O_CREAT|O_TRUNC, 0600)` →
  `ftruncate(540*1200*4)` → `mmap(PROT_READ, MAP_SHARED)`

### Expected vs actual

**Expected**: each notification corresponds to a new frame written into the mapped region.

**Actual** (grpc-swift, 400 notifications):

| | grpc-swift | grpcio |
|---|---|---|
| Notifications received | 400 | 400 |
| `Image.seq` | 1–400, contiguous, no repeats | 1–400, contiguous |
| Inter-arrival (median) | 15.7 ms (≈60 Hz, normal) | ~9–18 ms (derived: 400 frames per 3.4–7.1 s window) |
| **Distinct frame contents** | **1–23** | **376–400** |

### The decisive experiment: split "who issues the request" from "who owns the file"

This is the part we think matters most. In every earlier test, the same process created
the file, mapped it, and issued the gRPC request — so we could not tell which of those
mattered. We separated them:

- A **Swift** process creates the file, `mmap`s it, keeps the fd, and does all the reading.
- A **Python (grpcio)** child process issues the `streamScreenshot` MMAP request, with the
  handle pointing at the file the Swift process created.

| Role assignment | Distinct contents seen by the Swift reader |
|---|---|
| Swift creates + owns + **issues request** | 0–23 |
| Swift creates + owns, **Python issues request** | **277** |

**Same Swift process, same file, same mmap, same read loop — only the origin of the gRPC
request changed, and the problem disappears.** This is why we believe the difference is
server-side and keyed on something about the connection or request handling, not on the
client's file handling.

### Evidence that the writes are not reaching the file

Measured simultaneously, in a single run, on the same inode:

- Inside the Swift process: `mmap` reads and `pread` reads on the same fd agree
  **400/400 times**, and both see content that never changes.
- An unrelated external process, `open`+`read`ing **the same path at the same offset**,
  sees **182 content changes in 6.65 s** (~27/s, limited by our sampling rate).
- `fstat(fd).st_ino == stat(path).st_ino`, sizes match, mtime identical and unchanging.

So the file does change; the process that issued the grpc-swift request cannot see it.
(Note: this observation was taken while grpc-swift issued the request. Per the split
experiment above, the same process reads correctly when Python issues the request.)

### What we ruled out (all measured, not reasoned)

We spent a full day on this. None of these is the cause:

1. Emulator version (37.1.11 / 37.2.1 / 37.2.3 identical)
2. Request protobuf contents (decoded off the wire; semantically equivalent)
3. HTTP/2 SETTINGS (made grpcio match grpc-swift's `MAX_FRAME_SIZE=16384` / 8 MB window)
4. HTTP/2 flow control / `WINDOW_UPDATE` (grpc-swift sends 0, grpcio sends 15; forcing
   grpc-swift's `targetWindowSize` down to 64 KB and 16 KB changes nothing; disabling
   grpcio's BDP probe changes nothing)
5. HPACK headers (decoded; grpc-swift sends a completely ordinary set)
6. `:authority` (grpc-swift omits the port; making grpcio omit it too changes nothing)
7. Keeping the fd open after `mmap` vs closing it
8. `O_TRUNC` on the client's `open`
9. Stale mapping (`msync(MS_INVALIDATE)`, and re-`mmap`ing on **every** frame — no effect)
10. Sparse-file holes (pre-writing the whole file before `mmap` — no effect)
11. inode replacement (inode is stable throughout)
12. Client-side read cost (measured: 0.7 ms to copy 2.5 MB; the client spends its time
    waiting, not working)
13. Batched delivery (per-frame arrival timestamps: 400 clusters of size 1, no batching)
14. Host CPU contention (grpcio still gets 43% under load 23; grpc-swift gets 3.75% under
    load 6.5)
15. `TCP_NODELAY` (grpc-swift sets it)
16. Debug vs release build of the Swift client
17. A minimal reproduction **without** the emulator — same file creation sequence, another
    process writing via `mmap` — works correctly, so the client's file handling is sound

### One more clue we could not explain

Inserting a plain TCP relay (a small Python script that only forwards bytes) between the
grpc-swift client and the emulator **improves** the result substantially (distinct went
from 16 to 92 in a 400-frame window). The relay changes nothing but packet segmentation
and timing.

### Where we would look

`EmulatorService.cpp::getScreenshot`, the MMAP branch:

```cpp
shm = mSharedMemoryLibrary.borrow(request->transport().handle(), cPixels);
if (shm->isOpen() && shm->isMapped()) {
    cPixels = shm->size();
    pixels  = reinterpret_cast<uint8_t*>(shm->get());
    // ... transport fields filled in here
}   // no else — `pixels` keeps its previous (uninitialised) value
ScreenshotUtils::getScreenshot(..., pixels, &cPixels, ...);   // writes unconditionally
```

We do observe the `transport` field populated in the notifications, which suggests the
success branch is taken — but that is the only signal we have from outside. Also note
that `SharedMemoryLibrary::borrow` does not check the return value of
`shm->open(...)`, and `assert(shm->size() >= size)` is a no-op in release builds.

`borrow` is called twice per stream with different sizes (`width*height*bpp` at stream
start, `cPixels` per frame) while the header documents that "only the initial size
specification will be used" — we could not determine whether that matters here.

### Reproduction

The split-role experiment above is the shortest path to seeing this. In one process:

1. `open(path, O_RDWR|O_CREAT|O_TRUNC, 0600)` → `ftruncate(540*1200*4)` →
   `mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0)`, keep the fd
2. Issue `streamScreenshot` with `ImageFormat{RGBA8888, width: 540, height: 1200,
   transport: {channel: MMAP, handle: "file://" + path}}`
3. On each notification, read the mapped region and hash it

Do this twice — once with the request issued by grpc-swift, once by grpcio (from a child
process, so the file is still created and owned by the same process in both cases). The
grpcio run yields hundreds of distinct frames; the grpc-swift run yields a handful.

Two preconditions that are easy to miss: the guest screen must actually be changing
(`streamScreenshot` is change-driven — a static screen produces no frames at all), and
the sampling window must be long enough. We initially used a 3-frame window and misread
this as a hard freeze for over a week; at ~15 Hz effective update rate, 3 frames
(~150 ms) are identical almost every time. 400 frames makes the difference obvious.

We are happy to attach a runnable script if that would help.
