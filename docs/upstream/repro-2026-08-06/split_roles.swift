// D39 決定性實驗：拆開「誰發 gRPC 請求」與「誰持有那個檔案」。
//
// 到目前為止每個實驗裡，這兩件事都是同一個行程做的：Swift 建檔+持有+發請求（壞），
// Python 建檔+持有+發請求（好）。所以無法分辨問題跟著哪一個走。
//
// 這支腳本讓 **Swift 行程建立檔案、mmap、持有 fd 並負責讀**，而 **gRPC 請求由
// Python 子行程送出**（handle 指向 Swift 建的那個檔案）。
//
//   Swift 讀不到 → 問題跟著「持有檔案的行程」走，與 grpc-swift 無關
//   Swift 讀得到 → 問題跟著「發 gRPC 請求的 client」走，是 grpc-swift 的問題
//
// 跑法：swift split_roles.swift   （需 emulator 在 8554、guest 畫面正在變動）
import Foundation

let W = 540, H = 1200
let byteCount = W * H * 4
let harness = "/Users/hanfourhuang/Projects/mirage/phase0/harness"

// ── Swift 端：完全照 MmapBuffer.init 的順序 ──────────────────
let path = NSTemporaryDirectory() + "mirage_mmap_split_\(getpid()).bin"
let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
guard fd >= 0 else { fatalError("open 失敗") }
guard ftruncate(fd, off_t(byteCount)) == 0 else { fatalError("ftruncate 失敗") }
guard let base = mmap(nil, byteCount, PROT_READ, MAP_SHARED, fd, 0),
      base != MAP_FAILED else { fatalError("mmap 失敗") }
print("Swift 建立並持有：\(path)")

// ── Python 子行程：只負責送 gRPC 請求，不讀映射區 ─────────────
let pyScript = """
import sys
sys.path.insert(0, "\(harness)/gen"); sys.path.insert(0, "\(harness)")
import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.mmap_source import make_handle
path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
ch = grpc.insecure_channel("localhost:8554",
                           options=[("grpc.max_receive_message_length", -1)])
stub = ecg.EmulatorControllerStub(ch)
fmt = ec.ImageFormat(format=ec.ImageFormat.RGBA8888, width=w, height=h,
    transport=ec.ImageTransport(channel=ec.ImageTransport.MMAP,
                                handle=make_handle(path)))
n = 0
for _ in stub.streamScreenshot(fmt, timeout=30):
    n += 1
    if n >= 400: break
print(f"[python] 送出請求並收到 {n} 個通知", flush=True)
"""
let py = Process()
py.executableURL = URL(fileURLWithPath: "\(harness)/.venv/bin/python")
py.arguments = ["-c", pyScript, path, String(W), String(H)]
try py.run()

// ── Swift 端讀取：mmap 與 pread 各自計算相異內容 ──────────────
var viaMmap = Set<Int>(), viaPread = Set<Int>()
let deadline = Date().addingTimeInterval(9)
var samples = 0
while Date() < deadline {
    let snap = Data(bytes: base, count: byteCount)
    let lo = snap.index(snap.startIndex, offsetBy: 1 << 20)
    let hi = snap.index(lo, offsetBy: 4096)
    viaMmap.insert(Array(snap[lo..<hi]).hashValue)

    var buf = [UInt8](repeating: 0, count: 4096)
    if buf.withUnsafeMutableBytes({ pread(fd, $0.baseAddress, 4096, off_t(1 << 20)) }) == 4096 {
        viaPread.insert(buf.hashValue)
    }
    samples += 1
    usleep(20_000)
}
py.terminate()
munmap(base, byteCount)
close(fd)
unlink(path)

print("Swift 取樣 \(samples) 次：mmap 看到 \(viaMmap.count) 種、pread 看到 \(viaPread.count) 種")
print(viaMmap.count <= 2
      ? "→ **Swift 讀不到**：問題跟著「持有檔案的行程」走，與 grpc-swift 無關"
      : "→ **Swift 讀得到**：問題跟著「發 gRPC 請求的 client」走，是 grpc-swift 的問題")
