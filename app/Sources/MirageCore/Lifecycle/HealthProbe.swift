import Foundation
import GRPC

/// 健康探測結果：驅動連線 reducer 的 connectSucceeded / connectFailed。
///
/// `.healthy` 帶出 `EmulatorInfo`——`getStatus` 本來就回傳版本與 hardwareConfig，之前只
/// 取了版本。兩個消費者都需要它：transport 選路要版本（MMAP 需 ≥37，見 MmapVersionGate），
/// 觸控座標換算要 guest 實體解析度。讓探測順手帶出，比為了同一批資料另外打 RPC 便宜。
public enum HealthResult: Equatable, Sendable {
    case healthy(EmulatorInfo)      // getStatus 回覆且 booted
    case timedOut                   // 逾時未回覆
    case failed                     // 回覆錯誤或未 booted

    /// 便利建構——既有測試多半只關心版本，不必每處都寫出 display。
    public static func healthy(version: String) -> HealthResult {
        .healthy(EmulatorInfo(version: version, display: nil, booted: true))
    }
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
                    guard status.booted else { return .failed }
                    // hardwareConfig 是 key/value 陣列；重複鍵取後者（實務上不會有，
                    // 但 `uniqueKeysWithValues` 遇到重複會直接 trap，不值得為此冒險）。
                    let config = Dictionary(
                        status.hardwareConfig.entry.map { ($0.key, $0.value) },
                        uniquingKeysWith: { _, latest in latest })
                    return .healthy(EmulatorInfo(
                        version: status.version,
                        display: EmulatorInfo.displaySize(hardwareConfig: config),
                        booted: status.booted))
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
