import Foundation
import GRPC

/// 快照存/載抽象：以 protocol 注入，單元測試用假實作。
public protocol SnapshotSaving: Sendable {
    func save(_ id: String) async -> Bool     // 成功回 true，失敗回 false（降級，不擲錯）
    func load(_ id: String) async -> Bool
}

/// 生產實作：SnapshotService.SaveSnapshot/LoadSnapshot，format=directory（原地存載，不 streaming payload）。
/// 以 `channelBox` 建構（body 讀共用 channel）——對稱 GrpcHealthProbe(channel:)，避免 public
/// 預設引數表達式引用 internal 型別（P1-b Task 3 的相同編譯限制）。
public struct GrpcSnapshotService: SnapshotSaving {
    private let client: Android_Emulation_Control_SnapshotServiceAsyncClient

    public init(channelBox: GrpcChannelBox) {
        self.client = Android_Emulation_Control_SnapshotServiceAsyncClient(channel: channelBox.channel)
    }

    private func request(_ id: String) -> Android_Emulation_Control_SnapshotPackage {
        var pkg = Android_Emulation_Control_SnapshotPackage()
        pkg.snapshotID = id
        pkg.format = .directory
        return pkg
    }

    public func save(_ id: String) async -> Bool {
        do { return try await client.saveSnapshot(request(id)).success } catch { return false }
    }

    public func load(_ id: String) async -> Bool {
        do { return try await client.loadSnapshot(request(id)).success } catch { return false }
    }
}
