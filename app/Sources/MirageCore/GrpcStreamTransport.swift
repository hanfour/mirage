import Dispatch
import Foundation
import GRPC
import NIOCore
import NIOPosix

/// `streamScreenshot` 的 call 型別。raw RGBA 與 MMAP 兩條 transport 打的是同一支 RPC，
/// 只有 `ImageFormat.transport` 欄位不同，所以 call 型別完全相同。取個名字是因為這串
/// 泛型在三個型別、六個位置上逐字重複，而每次重複都是一次打錯的機會。
typealias ScreenshotCall = GRPCAsyncServerStreamingCall<
    Android_Emulation_Control_ImageFormat,
    Android_Emulation_Control_Image
>

/// 共用 gRPC 連線容器：transport 與輸入注入共用一條 channel。
public final class GrpcChannelBox: @unchecked Sendable {
    public let group: EventLoopGroup
    // ADAPTATION (compile-forced, see task-4-report.md): Generated stubs declare
    // `Android_Emulation_Control_EmulatorControllerAsyncClient` as `internal`
    // (default access), not `public`. `public let client: ...` fails to compile
    // ("property cannot be declared public because its type uses an internal
    // type"). `client` is only ever read from within MirageCore
    // (GrpcStreamTransport, EmulatorClient) and from `@testable import`-ing test
    // targets, so dropping `public` is the minimal fix. `GrpcChannelBox` itself
    // stays `public` — it appears in `EmulatorClient`'s public init signature.
    let client: Android_Emulation_Control_EmulatorControllerAsyncClient
    // `channel` 公開：GRPCChannel 是 grpc-swift 的 public 型別，`public let` 可直接編譯
    // （不同於上面 `client`——其產生型別為 internal，見上方註解）。供 SnapshotService 共用同一條連線。
    public let channel: GRPCChannel

    private let shutdownLock = NSLock()
    private var shutdownStarted = false

    public init(host: String, port: Int) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        channel = try GRPCChannelPool.with(
            target: .host(host, port: port),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        ) {
            $0.maximumReceiveMessageLength = 16 * 1024 * 1024
            // 預設 16 KB 會讓一幀 7 MB 切成約 440 個 DATA frame、每個都跑一次 HTTP/2 狀態機。
            // 調到上限後 898×1996、60 fps 三輪交錯量測每幀 CPU 約降 5%（2026-09-30）。
            $0.http2.maxFrameSize = 16_777_215
        }
        client = Android_Emulation_Control_EmulatorControllerAsyncClient(
            channel: channel,
            defaultCallOptions: Self.authenticatedOptions(token: EmulatorDiscovery.token(port: port)))
    }

    static func authenticatedOptions(token: String?, options: CallOptions = CallOptions()) -> CallOptions {
        var options = options
        if let token, !token.isEmpty {
            options.customMetadata.add(name: "authorization", value: "Bearer \(token)")
        }
        return options
    }

    /// 拆除這條連線。**不阻塞呼叫端執行緒**，可重複呼叫（第二次起是 no-op）。
    ///
    /// 順序不可調換，兩步各自解決一個實測到的症狀：
    ///
    /// 1. `channel.close()` —— 先關 pool。舊碼從不關 channel（全專案唯一的 `.close()` 是
    ///    `MmapBuffer` 的 munmap，不相關），只把 group 拆掉，於是**還活著的 pool** 之後
    ///    仍會想在已關閉的 loop 上排程，每次乾淨跑完的測試都會印數行
    ///    `Cannot schedule tasks on an EventLoop that has already shut down`
    ///    （2026-07-29 實測：通過的兩跑分別 3 行與 5 行）。SwiftNIO 自己的訊息說這在未來版本
    ///    會升級成強制崩潰。
    ///
    /// 2. `group.shutdownGracefully(queue:)` —— 回呼式，不阻塞。舊碼在 `deinit` 裡呼叫
    ///    **阻塞式**的 `syncShutdownGracefully()`，而 `deinit` 是被 `dropChannel()` 觸發的，
    ///    也就是跑在 Swift concurrency 的 cooperative 執行緒上。那個池的寬度等於核心數，
    ///    一旦每條執行緒都卡在這裡就沒有人能推進任何 Task，整個行程死鎖。
    ///    2026-07-29 實測（8 核）：連跑 5 次 `swift test`，2 次死鎖，兩份獨立 stack sample
    ///    都顯示**剛好 8 條** cooperative 執行緒全部停在
    ///    `dropChannel → channelBox.setter → GrpcChannelBox.deinit → syncShutdownGracefully
    ///     → semaphore_wait_trap`，同一時刻 NIO 的 event loop 執行緒全都閒置在 `kevent`。
    ///
    /// `ch` / `g` 先取到區域變數再進閉包：閉包因此持有它們的強參照，即使本物件在
    /// `close()` 尚未完成時就被釋放（deinit 路徑），channel 與 group 仍存活到拆除跑完。
    public func shutdown() {
        shutdownLock.lock()
        let first = !shutdownStarted
        shutdownStarted = true
        shutdownLock.unlock()
        guard first else { return }

        let ch = channel
        let g = group
        ch.close().whenComplete { _ in
            g.shutdownGracefully(queue: .global()) { _ in }
            withExtendedLifetime(ch) {}
        }
    }

    /// 最後防線。正常路徑上 `EmulatorClient.dropChannel()` 已顯式呼叫過 `shutdown()`，
    /// 此處是 no-op；留著是為了「有人新增了持有本型別的路徑卻忘了拆」時不至於洩漏 group。
    deinit { shutdown() }
}

/// 預設的顯示 transport：`streamScreenshot` 直送 raw RGBA。
///
/// **是 class 而非 struct**：必須長期持有底層 call 才能讓 `cancelStream()` 搆得到它。
/// 結構與生命週期完全比照 `GrpcAudioTransport`——同樣的問題、同樣的解法。
public final class GrpcStreamTransport: DisplayTransport, @unchecked Sendable {
    private let channel: GrpcChannelBox
    // call 型別非 Sendable，用鎖保護；@unchecked Sendable 的理由與既有 GrpcChannelBox 相同。
    private let lock = NSLock()
    private var call: ScreenshotCall?

    public init(channel: GrpcChannelBox) { self.channel = channel }

    /// timestampUs 為 0 表示未提供產生時間，傳輸延遲須為 nil，
    /// 避免把 Unix 紀元至今的巨大正值當成有效樣本。
    public func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        format.width = UInt32(width)
        format.height = UInt32(height)
        let log = ProcessInfo.processInfo.environment["MIRAGE_CONN_LOG"] == "1"
        // 用 makeStreamScreenshotCall 而非便利方法 client.streamScreenshot(_:)——後者只回傳
        // GRPCAsyncResponseStream，丟棄底層的 GRPCAsyncServerStreamingCall，於是沒有任何辦法
        // 顯式取消這條 RPC。MMAP 與音訊兩條路徑早就改用 make*Call 了（見
        // MmapStreamTransport.frames 與 GrpcAudioTransport.packets 的註解），唯獨這條
        // **預設開啟**的路徑一直沒改，而它正是 NIO 拆除死鎖的燃料。
        let call = channel.client.makeStreamScreenshotCall(format)
        // 重入保護，理由同 GrpcAudioTransport.packets()：setStreamSize 換源與重連都會
        // 再次呼叫 frames()，若不先取消舊 call 就覆蓋，舊 RPC 會被孤兒化、cancelStream()
        // 從此搆不到它。取出舊值與存入新值都在鎖內；GRPCAsyncServerStreamingCall 是 struct，
        // 取出的是值複本，鎖外對它 .cancel() 沒有 race。
        lock.lock()
        let previous = self.call
        self.call = call
        lock.unlock()
        previous?.cancel()

        // 只捕捉 responseStream（grpc-swift 明確標 Sendable），不捕捉 call 本身，
        // 否則 Task 閉包跨隔離傳遞會觸發 strict-concurrency 資料競爭警告。
        let responses = call.responseStream
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if log { print("[conn] streamScreenshot 已送出，等第一幀…") }
                    var n = 0
                    for try await img in responses {
                        n += 1
                        // 只印前兩幀與每 120 幀一次：要的是「有沒有開始流」與「有沒有停」，
                        // 不是逐幀噪音。
                        if log, n <= 2 || n % 120 == 0 {
                            print("[conn] 幀 #\(n) \(img.format.width)x\(img.format.height) bytes=\(img.image.count)")
                        }
                        continuation.yield(Frame(
                            width: Int(img.format.width),
                            height: Int(img.format.height),
                            rgba: img.image,
                            transitMs: img.timestampUs == 0 ? nil
                                : Date().timeIntervalSince1970 * 1000 - Double(img.timestampUs) / 1000))
                    }
                    if log { print("[conn] 串流自然結束，共 \(n) 幀") }
                    continuation.finish()
                } catch {
                    if log { print("[conn] 串流錯誤：\(error)") }
                    continuation.finish(throwing: error)
                }
            }
            // 這裡刻意只 task.cancel()，不順手呼叫 cancelStream()——比照 GrpcAudioTransport。
            // onTermination 是「某一條串流結束了」，而 self.call 永遠是**最新**那條；換源時
            // 舊串流的 onTermination 會晚於新 call 存入，在這裡取消就會誤殺剛掛上的新串流。
            // 真正的取消由 EmulatorClient.dropChannel() 顯式呼叫 cancelStream() 負責。
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 必須在 channel 拆除**之前**呼叫（見 `EmulatorClient.dropChannel` 的順序）：
    /// 先解決 in-flight promise，NIO 的 group 才能收斂。
    public func cancelStream() {
        lock.lock()
        let current = call
        call = nil
        lock.unlock()
        current?.cancel()
    }
}
