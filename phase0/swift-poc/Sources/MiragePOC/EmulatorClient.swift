// phase0/swift-poc/Sources/MiragePOC/EmulatorClient.swift
// gRPC 唯一封裝點：殼內其他元件不得直接 import GRPC。
import Foundation
import GRPC
import NIOCore
import NIOPosix
import SwiftProtobuf

struct Frame {
    let width: Int
    let height: Int
    let rgba: Data
}

final class EmulatorClient {
    // AUTHORIZED EXTENSION (deviation from brief, documented in task-7-report.md):
    // native RGBA8888 frames run ~10MiB (e.g. 1080x2400x4 bytes). grpc-swift v1's
    // ClientConnection default maximumReceiveMessageLength is 4MiB, which truncates
    // streamScreenshot with a resourceExhausted error. Raised to 16MiB to give headroom
    // above the largest expected native frame while still bounding memory use.
    private static let maxReceiveMessageLength = 16 * 1024 * 1024

    private let group: EventLoopGroup
    private let client: Android_Emulation_Control_EmulatorControllerAsyncClient

    init(host: String = "localhost", port: Int = 8554) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try GRPCChannelPool.with(
            target: .host(host, port: port),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        ) {
            $0.maximumReceiveMessageLength = Self.maxReceiveMessageLength
        }
        client = Android_Emulation_Control_EmulatorControllerAsyncClient(channel: channel)
    }

    func status() async throws -> String {
        let status = try await client.getStatus(Google_Protobuf_Empty())
        return status.textFormatString()
    }

    // AUTHORIZED EXTENSION (deviation from brief, documented in task-7-report.md):
    // optional width/height scaling, 0/0 == native. Defaulted so existing call sites
    // (main.swift's `client.frames()`) keep compiling unchanged.
    func frames(width: Int = 0, height: Int = 0) -> AsyncThrowingStream<Frame, Error> {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        format.width = UInt32(width)
        format.height = UInt32(height)
        let call = client.streamScreenshot(format)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await img in call {
                        continuation.yield(Frame(
                            width: Int(img.format.width),
                            height: Int(img.format.height),
                            rgba: img.image
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func sendTap(x: Int, y: Int, down: Bool) async {
        var touch = Android_Emulation_Control_Touch()
        touch.x = Int32(x)
        touch.y = Int32(y)
        touch.identifier = 0
        touch.pressure = down ? 1024 : 0
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = [touch]
        _ = try? await client.sendTouch(event)
    }

    deinit { try? group.syncShutdownGracefully() }
}
