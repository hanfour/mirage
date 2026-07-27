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
    /// 探測本體（含「串流提早結束」這條路徑）在 `MmapSupport.swift` 的 `MmapBlankProbe`，
    /// 拆成純狀態機是因為它可以完整單元測試，而本檔案（需要真 channel）不行。
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

        let format = Self.makeFormat(width: width, height: height,
                                     handleURL: MmapSupport.handleURL(path: buffer.path))
        // 用 makeStreamScreenshotCall 而非便利方法 client.streamScreenshot(_:)——後者丟棄
        // 底層 GRPCAsyncServerStreamingCall，無法顯式取消。那正是 P1-b 剪貼簿串流實證過、
        // 且架構債記錄點名為 crash 元兇的同一個坑。
        let call = channel.client.makeStreamScreenshotCall(format)
        // GRPCAsyncServerStreamingCall 非 Sendable，onTermination 是 @Sendable 閉包不能直接
        // 捕捉它；改捕捉這個 @unchecked Sendable box 轉發 cancel()（型別定義處有完整說明）。
        let callBox = MmapScreenshotCallBox(call)
        let responses = call.responseStream

        return AsyncThrowingStream { continuation in
            let task = Task {
                await Self.consume(responses: responses, buffer: buffer,
                                   width: width, height: height, into: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
                callBox.cancel()    // 顯式取消底層 RPC——Task.cancel() 中斷不了 in-flight next()
                buffer.close()      // munmap + close + unlink
            }
        }
    }

    private static func makeFormat(
        width: Int, height: Int, handleURL: String
    ) -> Android_Emulation_Control_ImageFormat {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        // **必須帶明確尺寸**：上游 b/537802959 的根因就是「請求裝置原生尺寸時
        // width*height 為 0，pre-borrow 用 0 大小並毒化 cache」。
        format.width = UInt32(width)
        format.height = UInt32(height)
        var transport = Android_Emulation_Control_ImageTransport()
        transport.channel = .mmap
        transport.handle = handleURL
        format.transport = transport
        return format
    }

    /// 消費 `responseStream`：每個通知代表映射區已有新內容，讀出快照、餵給探測狀態機，
    /// 依判定結果 yield / 跳過 / 判定不可用。串流自然結束時另外檢查探測是否完成——見
    /// `MmapBlankProbe.endedWithoutContent` 的說明（Critical 修正：提早結束不得放行成
    /// 乾淨結束）。
    private static func consume(
        responses: GRPCAsyncResponseStream<Android_Emulation_Control_Image>,
        buffer: MmapBuffer, width: Int, height: Int,
        into continuation: AsyncThrowingStream<Frame, Error>.Continuation
    ) async {
        var probe = MmapBlankProbe(frameBudget: blankProbeFrames)
        do {
            for try await _ in responses {
                if Task.isCancelled { return }
                let data = buffer.snapshot()
                switch probe.observe(isBlank: MmapSupport.isBlank(data)) {
                case .stillProbing:
                    continue        // 還在探測窗口內且全零：不送出黑幀
                case .unusable:
                    continuation.finish(throwing: TransportError.mmapUnusable(
                        "前 \(blankProbeFrames) 幀映射區皆全零"))
                    return
                case .deliver:
                    continuation.yield(Frame(width: width, height: height, rgba: data))
                }
            }
            if probe.endedWithoutContent() {
                continuation.finish(throwing: TransportError.mmapUnusable(
                    "映射區在探測完成前串流即結束"))
            } else {
                continuation.finish()
            }
        } catch {
            continuation.finish(throwing: TransportError.unavailable("\(error)"))
        }
    }
}

/// 掛載序號：確保每次 frames() 用不同的映射檔路徑（見 MmapSupport.handlePath 的說明）。
final class MmapSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

/// `GRPCAsyncServerStreamingCall` 不是 Sendable，無法直接被 `@Sendable` 的 `onTermination`
/// 閉包捕捉（strict concurrency 下會警告，Swift 6 語言模式下是錯誤）。包一層
/// `@unchecked Sendable` class 只為轉發 `cancel()`。
///
/// 這不是沿用 `GrpcAudioTransport` 的機制——那邊是類別長期持有一個受 `NSLock` 保護的
/// `var call`，由外部顯式呼叫的 `cancelStream()` 方法取消（適合它「同一個 instance 可能
/// 重連、被覆蓋」的生命週期）。這裡是全新的最小包裝：`call` 是 `private let`，建構後不再
/// 改變、也沒有第二個持有者會覆蓋它，`GRPCAsyncServerStreamingCall.cancel()` 本身設計上就
/// 可跨執行緒呼叫（grpc-swift 內部的 `withRPCCancellation` 也是從 cancellation handler
/// 呼叫它），因此不需要鎖。
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
