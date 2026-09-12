import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

/// 端點都指向沒人監聽的埠（CI 的 MIRAGE_PORT 與保留埠 1）：`switchInstance` 會真的
/// `client.start()`，連線迴圈對死埠退避重連，測試結尾一律 `client.stop()`。
@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppModelInstanceTests {
    private static func makeModel(_ tag: String) -> (AppModel, URL) {
        let (store, dir) = AppModelEditingTests.tempStore(tag)
        return (AppModel(store: store, starterBindings: { [] }), dir)
    }

    private let other = EmulatorInstance(avdName: "mirage-poc", consolePort: 5556, grpcPort: 1, pid: 2)

    @Test func currentEndpointStartsFromEnvironmentDefault() {
        let (model, dir) = Self.makeModel("endpoint-default")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.currentEndpoint == EmulatorClient.defaultEndpoint)
    }

    /// 選到目前這台：不斷線、不重連——否則每次誤點都白白斷一次串流。
    @Test func switchingToTheCurrentInstanceDoesNothing() async {
        let (model, dir) = Self.makeModel("switch-same")
        defer { try? FileManager.default.removeItem(at: dir) }
        let same = EmulatorInstance(avdName: "mirage-game", consolePort: 5554,
                                    grpcPort: EmulatorClient.defaultEndpoint.port, pid: 1)

        await model.switchInstance(to: same)

        #expect(!(await model.client.isRunning))          // 沒有被 start
        #expect(model.currentEndpoint == EmulatorClient.defaultEndpoint)
    }

    /// 切換 = stop → setEndpoint → start：切完 client 在跑、端點是新的、host 不變。
    @Test func switchingChangesClientEndpointAndRestarts() async {
        let (model, dir) = Self.makeModel("switch-other")
        defer { try? FileManager.default.removeItem(at: dir) }

        await model.switchInstance(to: other)

        #expect(model.currentEndpoint.port == 1)
        #expect(model.currentEndpoint.host == EmulatorClient.defaultEndpoint.host)
        #expect(await model.client.currentEndpoint.port == 1)
        #expect(await model.client.isRunning)
        await model.client.stop()
    }

    /// 切換沿用最後一次要求的串流尺寸，不退回 540x1200。
    @Test func switchingKeepsRequestedStreamSize() async {
        let (model, dir) = Self.makeModel("switch-size")
        defer { try? FileManager.default.removeItem(at: dir) }
        await model.client.start(box: model.box, width: 900, height: 2000)

        await model.switchInstance(to: other)

        let size = await model.client.requestedStreamSize
        #expect(size.w == 900)
        #expect(size.h == 2000)
        await model.client.stop()
    }

    /// 第二個要求在第一個切換期間送入，也必須完整切回原端點。
    @Test func consecutiveRequestsLeaveClientAndMenuOnTheLastEndpoint() async {
        let (model, dir) = Self.makeModel("switch-consecutive")
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = EmulatorInstance(avdName: "mirage-game", consolePort: 5554,
                                        grpcPort: model.currentEndpoint.port, pid: 1)
        let first = Task { @MainActor in await model.switchInstance(to: other) }
        // 等第一個要求入列；不依賴固定毫秒數或主機排程速度。
        while model.instanceSwitchTask == nil { await Task.yield() }
        await model.switchInstance(to: original)
        await first.value

        #expect(model.currentEndpoint.port == original.grpcPort)
        #expect(await model.client.currentEndpoint == model.currentEndpoint)
        #expect(await model.client.isRunning)
        await model.client.stop()
    }

}
