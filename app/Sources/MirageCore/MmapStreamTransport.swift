import Darwin
import Foundation
import GRPC

/// `streamScreenshot` + MMAP 共享記憶體的 DisplayTransport。
///
/// emulator 37 以上預設使用，並由 `FallbackTransport` 在偵測到內容停止更新時切回 raw。
/// 2026-10-01 交錯重測（898×1996）：raw 59.3–60.0 fps、MMAP 59.6–59.9 fps；接收端 CPU
/// 34.7–36.4% 對 12.6–13.1%，qemu CPU 216–232% 對 173–186%。先前 grpc-swift 畫面異常的
/// 原因仍未查明；重測條件與完整數字見 `app/RESULTS-mmap.md`。
///
/// 相對於 `GrpcStreamTransport`（raw RGBA payload 走 protobuf），本實作讓 emulator 直接把
/// 像素寫進我們提供的映射區，通知訊息的 payload 為空。**下面這組數字是 Python harness
/// （grpcio 直連，不經過本型別）量到的主機能力上限，不是本型別的實測收益：client 每幀
/// CPU 8.0 → 0.7 ms、經 gRPC 的位元組 272 → 0 MiB/s（900×2000，spec §1.1）。
public struct MmapStreamTransport: DisplayTransport {
    /// 前幾幀若映射區全零就判定 host 寫入端無作用，丟 .mmapUnusable 讓上層降級。
    /// 偏誤方向刻意：寧可誤降級（只是多花 CPU、畫面正確）也不要誤啟用（黑畫面）。
    /// 探測本體在 `MmapSupport.swift` 的 `MmapBlankProbe`，拆成純狀態機以便完整單元測試。
    static let blankProbeFrames = 3

    private let channel: GrpcChannelBox
    private let seq = MmapSequence()
    /// 最新一條 call 的存放處，只給 `cancelStream()` 用。本型別是 struct，可變狀態一律
    /// 委託給參照型別（同 `seq` 的既有作法）。
    private let latest = ScreenshotCallSlot()

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
        latest.store(call)?.cancel()        // 重入保護，理由同 GrpcStreamTransport.frames()
        // GRPCAsyncServerStreamingCall 非 Sendable，onTermination 是 @Sendable 閉包不能直接
        // 捕捉它；改捕捉這個 @unchecked Sendable box 轉發 cancel()（型別定義處有完整說明）。
        let callBox = MmapScreenshotCallBox(call)
        let responses = call.responseStream

        let channel = self.channel
        return AsyncThrowingStream { continuation in
            // 快照指紋與 unary raw 比對不繼承呼叫端的 actor 隔離，避免跑在 UI actor 上。
            let task = Task.detached {
                await Self.consume(responses: responses, buffer: buffer,
                                   width: width, height: height, channel: channel,
                                   into: continuation)
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

    /// 顯式取消最新一條 RPC。與 `onTermination` 裡的 `callBox.cancel()` 不重複：那個是
    /// per-stream（取消它自己捕捉的那條，換源時不會誤殺新串流），這個是 per-instance
    /// （`dropChannel()` 拆 channel 前的顯式取消）。`cancel()` 冪等，重複呼叫無害。
    public func cancelStream() { latest.take()?.cancel() }

    /// 消費 `responseStream`：每個通知代表映射區已有新內容，讀出快照、餵給探測狀態機，
    /// 依判定結果 yield / 跳過 / 判定不可用。串流自然結束時另外檢查探測是否完成——見
    /// `MmapBlankProbe.endedWithoutContent` 的說明（Critical 修正：提早結束不得放行成
    /// 乾淨結束）。
    private static func consume(
        responses: GRPCAsyncResponseStream<Android_Emulation_Control_Image>,
        buffer: MmapBuffer, width: Int, height: Int, channel: GrpcChannelBox,
        into continuation: AsyncThrowingStream<Frame, Error>.Continuation
    ) async {
        var probe = MmapBlankProbe(frameBudget: blankProbeFrames)
        var stallDetector = MmapStallDetector()
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
                    continuation.yield(Frame(width: width, height: height, rgba: data, transitMs: nil))
                    let fingerprint = MmapSupport.fingerprint(of: data)
                    let decision = stallDetector.observe(
                        fingerprint: fingerprint,
                        at: ProcessInfo.processInfo.systemUptime
                    )
                    guard case .compareRaw = decision else { continue }

                    let comparison = await compareWithRaw(
                        client: channel.client,
                        snapshot: data,
                        width: width,
                        height: height
                    )
                    if Task.isCancelled { return }
                    let resolution = stallDetector.resolve(
                        comparison,
                        at: ProcessInfo.processInfo.systemUptime
                    )
                    switch resolution {
                    case .continueMmap:
                        continue
                    case .unusable(let count):
                        continuation.finish(throwing: TransportError.mmapUnusable(
                            "內容停止更新（連續 \(count) 次通知相同、raw 比對不同）"
                        ))
                        return
                    case .comparisonFailed(let message):
                        print("[transport] mmap raw 比對失敗：\(message)，暫不判定不可用")
                    case .incomparable(let rawWidth, let rawHeight):
                        print("[transport] mmap raw 比對尺寸不同（\(rawWidth)x\(rawHeight)），無法判定內容")
                    }
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

    /// 用同一條已帶授權 metadata 的 client 取 raw RGBA。`getScreenshot` 刻意不傳 callOptions，
    /// 否則會蓋掉 GrpcChannelBox 建立 client 時設定的 token header。
    private static func compareWithRaw(
        client: Android_Emulation_Control_EmulatorControllerAsyncClient,
        snapshot: Data,
        width: Int,
        height: Int
    ) async -> MmapStallDetector.RawComparison {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        format.width = UInt32(width)
        format.height = UInt32(height)

        do {
            let image = try await client.getScreenshot(format)
            let rawWidth = Int(image.format.width)
            let rawHeight = Int(image.format.height)
            guard rawWidth == width, rawHeight == height else {
                return .incomparable(width: rawWidth, height: rawHeight)
            }
            let expectedByteCount = MmapSupport.byteCount(width: width, height: height)
            guard image.image.count == expectedByteCount else {
                return .failed("raw RGBA 位元組數為 \(image.image.count)，預期 \(expectedByteCount)")
            }
            return image.image == snapshot ? .same : .different
        } catch {
            return .failed(String(describing: error))
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
    private let call: ScreenshotCall
    init(_ call: ScreenshotCall) { self.call = call }
    func cancel() { call.cancel() }
}

/// 「最新一條 screenshot call」的可變存放處，供 `cancelStream()` 顯式取消。
///
/// 與上面的 `MmapScreenshotCallBox` 是不同用途，刻意分成兩個型別而不是合併成一個可變 box：
/// 那個是 per-stream、不可變，給 `onTermination` 取消**它自己那條**；這個是 per-instance、
/// 可變，只保留最新那條。合併會讓 `onTermination` 取消到最新的 call，換源時誤殺剛掛上的新串流。
final class ScreenshotCallSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var call: ScreenshotCall?

    /// 存入新 call，回傳被它取代的舊 call（呼叫端負責 cancel，避免在鎖內做 I/O）。
    @discardableResult
    func store(_ new: ScreenshotCall) -> ScreenshotCall? {
        lock.lock(); defer { lock.unlock() }
        let previous = call
        call = new
        return previous
    }

    /// 取出並清空。
    func take() -> ScreenshotCall? {
        lock.lock(); defer { lock.unlock() }
        let current = call
        call = nil
        return current
    }
}
