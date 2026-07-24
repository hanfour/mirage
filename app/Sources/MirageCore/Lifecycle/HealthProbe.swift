import Foundation
import GRPC

/// 健康探測結果：驅動連線 reducer 的 connectSucceeded / connectFailed。
public enum HealthResult: Equatable, Sendable {
    case healthy    // getStatus 回覆且 booted
    case timedOut   // 逾時未回覆
    case failed     // 回覆錯誤或未 booted
}

/// 探測抽象：以 protocol 注入，單元測試用假探測，不碰網路。
public protocol HealthProbe: Sendable {
    func probe(timeout: Duration) async -> HealthResult
}

/// 生產實作：呼叫 getStatus，逾時以 Task race 實作（不改 gRPC deadline，避免影響 pool）。
public struct GrpcHealthProbe: HealthProbe {
    private let client: Android_Emulation_Control_EmulatorControllerAsyncClient

    // ADAPTATION (compile-forced, same root cause as GrpcChannelBox.client in
    // GrpcStreamTransport.swift): the generated
    // `Android_Emulation_Control_EmulatorControllerAsyncClient` is `internal`
    // (default access), not `public`. A `public init` cannot take it as a
    // parameter ("initializer cannot be declared public because its parameter
    // uses an internal type"). Dropping `public` here is the minimal fix — the
    // type itself stays `public` (satisfies the public `HealthProbe`
    // conformance), only construction is confined to within MirageCore, e.g.
    // via `EmulatorClient`'s default `healthProbe` factory (Task 3) using
    // `GrpcChannelBox.client`.
    init(client: Android_Emulation_Control_EmulatorControllerAsyncClient) {
        self.client = client
    }

    public func probe(timeout: Duration) async -> HealthResult {
        await withTaskGroup(of: HealthResult.self) { group in
            group.addTask {
                do {
                    let status = try await client.getStatus(.init())
                    return status.booted ? .healthy : .failed
                } catch {
                    return .failed
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }
    }
}
