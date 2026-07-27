import Darwin
import Foundation
import GRPC

/// `streamScreenshot` + MMAP 共享記憶體的 DisplayTransport。
///
/// 相對於 `GrpcStreamTransport`（raw RGBA payload 走 protobuf），本實作讓 emulator 直接把
/// 像素寫進我們提供的映射區，通知訊息的 payload 為空。實測收益（900×2000，spec §1.1）：
/// client 每幀 CPU 8.0 → 0.7 ms、經 gRPC 的位元組 272 → 0 MiB/s。
public struct MmapStreamTransport: DisplayTransport {
    /// 前幾幀若映射區全零就判定 host 寫入端無作用 → 丟 .mmapUnusable 讓上層降級。
    /// 偏誤方向刻意：寧可誤降級（只是多花 CPU、畫面正確）也不要誤啟用（黑畫面）。
    static let blankProbeFrames = 3

    private let channel: GrpcChannelBox
    private let seq = MmapSequence()

    public init(channel: GrpcChannelBox) { self.channel = channel }

    public func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        let size = MmapSupport.byteCount(width: width, height: height)
        let path = MmapSupport.handlePath(tempDir: NSTemporaryDirectory(), pid: getpid(),
                                          seq: seq.next(), width: width, height: height)
        guard size > 0, let buffer = MmapBuffer(path: path, byteCount: size) else {
            return AsyncThrowingStream { cont in
                cont.finish(throwing: TransportError.mmapUnusable(
                    "無法建立 \(size) 位元組的映射（\(path)）"))
            }
        }

        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        // **必須帶明確尺寸**：上游 b/537802959 的根因就是「請求裝置原生尺寸時
        // width*height 為 0，pre-borrow 用 0 大小並毒化 cache」。
        format.width = UInt32(width)
        format.height = UInt32(height)
        var transport = Android_Emulation_Control_ImageTransport()
        transport.channel = .mmap
        transport.handle = MmapSupport.handleURL(path: buffer.path)
        format.transport = transport

        // 用 makeStreamScreenshotCall 而非便利方法 client.streamScreenshot(_:)——後者丟棄
        // 底層 GRPCAsyncServerStreamingCall，無法顯式取消。那正是 P1-b 剪貼簿串流實證過、
        // 且架構債記錄點名為 crash 元兇的同一個坑。
        let call = channel.client.makeStreamScreenshotCall(format)
        // GRPCAsyncServerStreamingCall 非 Sendable，onTermination 是 @Sendable 閉包，
        // 不能直接捕捉 call（比照既有 GrpcAudioTransport 的做法：只捕捉 Sendable 的
        // responseStream 供消費迴圈用；cancel 另外透過這個 @unchecked Sendable box 轉發）。
        let callBox = MmapScreenshotCallBox(call)
        let responses = call.responseStream

        return AsyncThrowingStream { continuation in
            let task = Task {
                var seen = 0
                var sawContent = false
                do {
                    for try await _ in responses {
                        if Task.isCancelled { return }
                        let data = buffer.snapshot()
                        if !sawContent {
                            seen += 1
                            if !MmapSupport.isBlank(data) {
                                sawContent = true
                            } else if seen >= Self.blankProbeFrames {
                                continuation.finish(throwing: TransportError.mmapUnusable(
                                    "前 \(Self.blankProbeFrames) 幀映射區皆全零"))
                                return
                            } else {
                                continue        // 還在探測窗口內且全零：不送出黑幀
                            }
                        }
                        continuation.yield(Frame(width: width, height: height, rgba: data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: TransportError.unavailable("\(error)"))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                callBox.cancel()    // 顯式取消底層 RPC——Task.cancel() 中斷不了 in-flight next()
                buffer.close()      // munmap + close + unlink
            }
        }
    }
}

/// 掛載序號：確保每次 frames() 用不同的映射檔路徑（見 MmapSupport.handlePath 的說明）。
final class MmapSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

/// `GRPCAsyncServerStreamingCall` 不是 Sendable，無法直接被 `@Sendable` 的
/// `onTermination` 閉包捕捉（strict concurrency 下會警告/報錯）。包一層
/// `@unchecked Sendable` class 只為轉發 `cancel()`——call 建檔後不再變動、
/// `cancel()` 本身冪等，故不需要額外上鎖（比照 GrpcChannelBox 的慣例）。
final class MmapScreenshotCallBox: @unchecked Sendable {
    private let call: GRPCAsyncServerStreamingCall<
        Android_Emulation_Control_ImageFormat,
        Android_Emulation_Control_Image
    >
    init(_ call: GRPCAsyncServerStreamingCall<
        Android_Emulation_Control_ImageFormat,
        Android_Emulation_Control_Image
    >) {
        self.call = call
    }
    func cancel() { call.cancel() }
}
