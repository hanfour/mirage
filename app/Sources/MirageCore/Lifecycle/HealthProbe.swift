import Foundation
import GRPC

/// 健康探測結果：驅動連線 reducer 的 connectSucceeded / connectFailed。
///
/// `.healthy` 帶出 emulator 版本字串——`getStatus` 本來就回傳它，之前被丟棄。
/// 由連線層決定要建哪種 transport（MMAP 需 ≥37，見 MmapVersionGate）需要這個資訊，
/// 讓探測順手帶出比另外打一次 RPC 便宜。
public enum HealthResult: Equatable, Sendable {
    case healthy(version: String)   // getStatus 回覆且 booted，帶版本字串
    case timedOut                   // 逾時未回覆
    case failed                     // 回覆錯誤或未 booted
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
    // uses an internal type"), and — the Task 3 trigger — a `public init(client:)`
    // referenced from EmulatorClient's PUBLIC default argument fails ("initializer
    // 'init(client:)' is internal and cannot be referenced from a default argument
    // value"). Mirroring the sibling `GrpcStreamTransport.init(channel:)`, we
    // expose a `public init(channel: GrpcChannelBox)` whose BODY reads the
    // internal `channel.client` (bodies may reference internal symbols; default
    // argument EXPRESSIONS may not). The public type still satisfies the public
    // `HealthProbe` conformance; construction stays confined to MirageCore via
    // EmulatorClient's default `makeHealthProbe` factory `{ GrpcHealthProbe(channel: $0) }`.
    public init(channel: GrpcChannelBox) {
        self.client = channel.client
    }

    public func probe(timeout: Duration) async -> HealthResult {
        await withTaskGroup(of: HealthResult.self) { group in
            group.addTask {
                do {
                    let status = try await client.getStatus(.init())
                    return status.booted ? .healthy(version: status.version) : .failed
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
