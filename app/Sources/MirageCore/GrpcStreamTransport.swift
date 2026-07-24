import Foundation
import GRPC
import NIOCore
import NIOPosix

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

    public init(host: String, port: Int) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        channel = try GRPCChannelPool.with(
            target: .host(host, port: port),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        ) {
            $0.maximumReceiveMessageLength = 16 * 1024 * 1024
        }
        client = Android_Emulation_Control_EmulatorControllerAsyncClient(channel: channel)
    }

    deinit { try? group.syncShutdownGracefully() }
}

public struct GrpcStreamTransport: DisplayTransport {
    private let channel: GrpcChannelBox

    public init(channel: GrpcChannelBox) { self.channel = channel }

    public func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        format.width = UInt32(width)
        format.height = UInt32(height)
        let call = channel.client.streamScreenshot(format)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await img in call {
                        continuation.yield(Frame(
                            width: Int(img.format.width),
                            height: Int(img.format.height),
                            rgba: img.image))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
