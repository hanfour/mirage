import Testing
@testable import MirageCore
@testable import MirageShell

/// `MirrorView.Coordinator` 的滑鼠→tap 路徑。
///
/// 這條路徑在 D21 之前**零自動化涵蓋**——`Coordinator` 只吃具體型別 `EmulatorClient`，
/// 沒有真 gRPC channel 就觀察不到它送出了什麼。D6 要求 tap 與其他輸入走同一條佇列，
/// 補完那道縫之後才有辦法對它寫斷言。
@MainActor
@Suite struct MirrorCoordinatorTests {
    /// D6：無 profile 時滑鼠退回直接 tap（spec §7 驗收 4，P1-a 不回歸的核心保證），
    /// 而那條路徑的 down/up 同樣不得對調——對調就是 guest 的手指永遠按著。
    @Test(.timeLimit(.minutes(1)))
    func tapsReachGuestInPressOrder() async {
        let probe = OrderProbe { $0.hasSuffix("down") ? .milliseconds(60) : .milliseconds(10) }
        let coordinator = MirrorView.Coordinator(
            client: EmulatorClient(), queue: InputQueue(injector: probe))
        coordinator.sendMouse(nx: 0.5, ny: 0.5, down: true)
        coordinator.sendMouse(nx: 0.5, ny: 0.5, down: false)
        await probe.waitForArrivals(2)
        #expect(probe.arrivals == ["tap 0.5 down", "tap 0.5 up"])
    }

    /// D22：編輯模式下滑鼠一律不得送到 guest——不管有沒有 profile。
    ///
    /// 使用者在編輯器裡拖鍵位，等於在遊戲畫面上亂點。這是階段 B 拖曳功能的前置條件：
    /// 不先修掉，拖曳一上線就是在髒環境上開發。
    @Test(.timeLimit(.minutes(1)))
    func editingModeSendsNoTapEvenWithoutProfile() async {
        let probe = OrderProbe { _ in .zero }
        let coordinator = MirrorView.Coordinator(
            client: EmulatorClient(), queue: InputQueue(injector: probe))
        coordinator.isEditing = true

        coordinator.sendMouse(nx: 0.5, ny: 0.5, down: true)
        coordinator.sendMouse(nx: 0.5, ny: 0.5, down: false)

        // 否定斷言用固定等待：這條路徑若有送出，事件會在幾毫秒內抵達探針。
        try? await Task.sleep(for: .milliseconds(150))
        #expect(probe.arrivals.isEmpty)
    }

    /// D22 這個 task 賴以成立的姊妹 guard：有作用中 profile、不在編輯模式時，
    /// `sendMouse` 不得送出直接 tap——這時鍵鼠已經改走 KeymapController → KeymapEngine，
    /// 這裡若還送一次 tap，guest 會同時收到觸控與直接 tap 兩份輸入。
    ///
    /// 這條路徑（`controller?.hasProfile != true` guard）先於這次改動就存在，但一直是
    /// `app/Tests` 裡零涵蓋的不變式——`isEditing` guard 的正確性正好建立在它之上，
    /// 補的位置也緊挨著它，一起補齊才算把 D22 這個函式的兩道 guard 都驗過。
    @Test(.timeLimit(.minutes(1)))
    func hasProfileSendsNoTapWhenNotEditing() async {
        let probe = OrderProbe { _ in .zero }
        let queue = InputQueue(injector: probe)
        let profile = KeymapProfile(gameId: "g", version: 1, bindings: [])
        let controller = KeymapController(queue: queue, profile: profile)
        let coordinator = MirrorView.Coordinator(client: EmulatorClient(), queue: queue)
        coordinator.controller = controller
        // isEditing 預設 false——這條路徑要驗的是「有 profile、非編輯模式」本身就該
        // 退回引擎，不是靠 isEditing guard 順帶擋下來。

        coordinator.sendMouse(nx: 0.5, ny: 0.5, down: true)
        coordinator.sendMouse(nx: 0.5, ny: 0.5, down: false)

        // 否定斷言用固定等待，理由同上一條。
        try? await Task.sleep(for: .milliseconds(150))
        #expect(probe.arrivals.isEmpty)
    }
}
