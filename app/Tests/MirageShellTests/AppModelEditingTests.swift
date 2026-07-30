import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

@MainActor
@Suite struct AppModelEditingTests {
    /// 測試用的暫存 store——**不得碰使用者真實的 Application Support 目錄**。
    static func tempStore(_ tag: String) -> (ProfileStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirage-appmodel-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ProfileStore(directory: dir), dir)
    }

    /// 注入縫本身：構造時用得上注入的 store 與 starter 來源，且不碰真實目錄。
    @Test func constructsWithInjectedDependencies() {
        let (store, dir) = Self.tempStore("construct")
        defer { try? FileManager.default.removeItem(at: dir) }
        let starter: [Binding] = [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))]

        let model = AppModel(store: store, starterBindings: { starter })

        #expect(model.currentPackage == nil)
        model.currentPackage = "com.game.injected"      // private(set) 時這行編不過
        #expect(model.currentPackage == "com.game.injected")
    }

    /// 階段 A 的核心：沒有 profile 但知道在玩什麼 → ⌘E 要打得開，且帶著 starter 版面。
    ///
    /// 呼叫 `loadKeymap()`——沒有它 `model.keymap` 恆為 nil，`toggleEditing()` 裡的
    /// `keymap?.reload(p)` 從未真的執行過，測試會因為錯誤的理由而綠（I1）。
    @Test func editingOpensWithStarterWhenNoProfileExists() {
        let (store, dir) = Self.tempStore("starter")
        defer { try? FileManager.default.removeItem(at: dir) }
        let starter: [Binding] = [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))]
        let model = AppModel(store: store, starterBindings: { starter })
        model.loadKeymap()
        model.currentPackage = "com.loomgames.pixelflow"

        model.toggleEditing()

        #expect(model.editing)
        #expect(model.profile?.gameId == "com.loomgames.pixelflow")
        #expect(model.profile?.version == 1)
        #expect(model.profile?.bindings == starter)
        #expect(model.keymap?.hasProfile == true)
    }

    /// **未存檔不落檔**：⌘E 只在記憶體裡建 starter，磁碟上不得出現任何檔案。
    /// 不小心按到 ⌘E 就憑空生出一個檔案，是「明確存檔」語意不能接受的。
    @Test func openingEditorWritesNothingToDisk() throws {
        let (store, dir) = Self.tempStore("nodisk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))] })
        model.currentPackage = "com.game.nodisk"

        model.toggleEditing()

        // 先確認 toggleEditing 真的做了事——否則下面的「目錄是空的」會因為
        // 「什麼都沒發生」而通過，那是綠得毫無意義。
        #expect(model.editing)
        #expect(model.profile?.gameId == "com.game.nodisk")

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.isEmpty, "⌘E 不得落檔，實得 \(files)")
    }

    /// 不知道在玩什麼就沒有 gameId 可以掛——維持現行的「不動作」。
    @Test func editingStaysClosedWithoutPackageOrProfile() {
        let (store, dir) = Self.tempStore("nopkg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))] })

        model.toggleEditing()

        #expect(!model.editing)
        #expect(model.profile == nil)
    }

    /// 已在編輯模式時一定出得來——即使途中 profile 被收成 nil。
    @Test func editingAlwaysCloses() {
        let (store, dir) = Self.tempStore("close")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))] })
        model.currentPackage = "com.game.close"
        model.toggleEditing()
        #expect(model.editing)

        model.profile = nil          // 模擬偵測途中把遊戲切成 .inactive
        model.toggleEditing()

        #expect(!model.editing)
    }

    /// C1（Critical，D5 階段 A 終審）：⌘E 進去又出來（未存檔），不得把 starter 留在 session 裡。
    ///
    /// 原本 `.leave` 只做 `editing = false`，不還原 `profile`、不清引擎——磁碟乾淨，
    /// session 卻髒了：`shouldCapture` 仍會成立（隱藏游標、解除滑鼠關聯），fallback
    /// starter 的 `.look(activation: nil)` 是 always-on，滑鼠一動就在 guest 上拖曳，而
    /// `Coordinator.sendMouse` 因為 `hasProfile == true` 提早 return，連「點一下＝tap」
    /// 都沒了。使用者只是按了兩次 ⌘E、什麼都沒存，卻換了一套他從沒設定過的輸入模式。
    ///
    /// 這條測試會在把 `toggleEditing()` 的 `.leave` 分支裡 `applyActivation()` 那行拿掉時
    /// 變紅——已手動驗證過（見 final-fix-report.md）。
    @Test func leavingUnsavedEditDoesNotLeakStarterIntoSession() throws {
        let (store, dir) = Self.tempStore("leak")
        defer { try? FileManager.default.removeItem(at: dir) }
        let starter: [Binding] = [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))]
        let model = AppModel(store: store, starterBindings: { starter })
        model.loadKeymap()
        model.currentPackage = "com.game.leak"

        model.toggleEditing()   // 進：套用 starter
        #expect(model.editing)
        model.toggleEditing()   // 出：未存檔

        #expect(!model.editing)
        #expect(model.profile == nil)
        #expect(model.keymap?.hasProfile == false)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.isEmpty, "未存檔不落檔，實得 \(files)")
    }

    /// I3（Important，D5 階段 A 終審）：編輯途中收到偵測/覆寫通知（`setOverride` 與
    /// `GameDetector` 回呼共用 `applyActivation()` 這條路），不得把記憶體裡還沒存檔的
    /// starter 收掉。原本 `applyActivation()` 找不到磁碟上的檔就走 `.inactive`，把
    /// `profile` 清成 nil、引擎跟著清空——編輯器 UI（`if editing, let profile`）因此
    /// 整個消失，但 App 仍在編輯模式（滑鼠被擋、鍵盤直通被擋），畫面上沒有任何提示、
    /// 也沒有可見出口。
    @Test func detectionDuringEditingDoesNotClearInMemoryProfile() {
        let (store, dir) = Self.tempStore("i3")
        defer { try? FileManager.default.removeItem(at: dir) }
        let starter: [Binding] = [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))]
        let model = AppModel(store: store, starterBindings: { starter })
        model.loadKeymap()
        model.currentPackage = "com.game.i3"
        model.toggleEditing()
        #expect(model.editing)
        let editedProfile = model.profile

        model.setOverride(.auto)   // 與遊戲偵測回呼同一條路（AppModel.onForeground → applyActivation）

        #expect(model.editing)
        #expect(model.profile == editedProfile)
        #expect(model.keymap?.hasProfile == true)
    }

    /// 幀尺寸要流得到 `AppModel`——Scene 層的 overlay 靠它算 letterbox 內容矩形。
    /// 預設 (0, 0) 代表「還沒收到任何幀」，此時 `ViewportFit.fit` 回 `.zero`，overlay 不畫。
    @Test func frameSizeStartsUnknownAndIsSettable() {
        let (store, dir) = Self.tempStore("framesize")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))] })

        #expect(model.frameSize.w == 0)
        #expect(model.frameSize.h == 0)
        #expect(ViewportFit.fit(frame: model.frameSize, in: (w: 1000, h: 1000)) == .zero)

        model.frameSize = (w: 1080, h: 2400)
        #expect(ViewportFit.fit(frame: model.frameSize, in: (w: 1000, h: 1000))
                == FitRect(x: 275, y: 0, width: 450, height: 1000))
    }

    /// 進編輯 → 建立 session；離開 → 清掉。session 的內容要對應當下的 profile。
    @Test func editorSessionLifecycleFollowsEditingMode() {
        let (store, dir) = Self.tempStore("session")
        defer { try? FileManager.default.removeItem(at: dir) }
        let starter: [Binding] = [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.12),
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.82)),
        ]
        let model = AppModel(store: store, starterBindings: { starter })
        model.currentPackage = "com.game.session"
        #expect(model.editorSession == nil)

        model.toggleEditing()
        #expect(model.editorSession?.items.map(\.binding) == starter)
        #expect(model.editorSession?.gameId == "com.game.session")
        #expect(model.editorSession?.isDirty == false)

        model.toggleEditing()
        #expect(model.editorSession == nil)          // 離開就收掉，不留殘影
    }

    /// 選取經由 `AppModel` 走，overlay 與抽屜因此看到同一份狀態。
    @Test func selectBindingUpdatesTheSession() {
        let (store, dir) = Self.tempStore("select")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.select"
        model.toggleEditing()
        let id = try! #require(model.editorSession?.items.first?.id)

        model.selectBinding(id)
        #expect(model.editorSession?.selectedID == id)
        #expect(model.editorSession?.isDirty == false)   // 選取不是變更

        model.selectBinding(nil)
        #expect(model.editorSession?.selectedID == nil)
    }

    /// 存檔：寫進注入的 store、version+1、引擎立即套用，且 session 重置為不髒。
    @Test func savingEditorSessionWritesAndReloads() throws {
        let (store, dir) = Self.tempStore("save")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.save"
        model.loadKeymap()
        model.toggleEditing()

        model.saveEditorSession()

        let saved = try store.load(gameId: "com.game.save")
        #expect(saved.gameId == "com.game.save")
        #expect(saved.version == 2)                       // starter 是 version 1
        #expect(model.profile == saved)
        #expect(model.editorSession?.isDirty == false)
        #expect(model.keymap?.hasProfile == true)
    }

    /// 拖曳落點寫回 session，並**即時套用到引擎**——使用者要看到圈跟著手走。
    @Test func movingSelectedBindingUpdatesSessionAndEngine() throws {
        let (store, dir) = Self.tempStore("move")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.move"
        model.loadKeymap()
        model.toggleEditing()
        let id = try #require(model.editorSession?.items.first?.id)
        model.selectBinding(id)

        model.moveSelectedBinding(to: NormPoint(x: 0.25, y: 0.4))

        if case .tap(_, let at) = try #require(model.editorSession?.items.first?.binding) {
            #expect(at == NormPoint(x: 0.25, y: 0.4))
        } else {
            Issue.record("期待 .tap")
        }
        #expect(model.editorSession?.isDirty == true)
        // 即時套用：`profile` 與引擎都要看到新位置，否則離開編輯後才會突然跳位。
        if case .tap(_, let at) = try #require(model.profile?.bindings.first) {
            #expect(at == NormPoint(x: 0.25, y: 0.4))
        } else {
            Issue.record("期待 .tap")
        }
    }

    /// 沒有選取時拖曳是 no-op，不得憑空改到別的 binding。
    @Test func movingWithoutSelectionChangesNothing() throws {
        let (store, dir) = Self.tempStore("move-none")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.move.none"
        model.toggleEditing()
        let before = try #require(model.editorSession)

        model.moveSelectedBinding(to: NormPoint(x: 0.1, y: 0.1))

        #expect(model.editorSession == before)
        #expect(model.editorSession?.isDirty == false)
    }

    /// 半徑寫回 session 並即時套用；作用在非搖桿上是 no-op。
    @Test func settingRadiusUpdatesJoystickOnly() throws {
        let (store, dir) = Self.tempStore("radius")
        defer { try? FileManager.default.removeItem(at: dir) }
        let starter: [Binding] = [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.12),
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.82)),
        ]
        let model = AppModel(store: store, starterBindings: { starter })
        model.currentPackage = "com.game.radius"
        model.loadKeymap()
        model.toggleEditing()
        let stickID = try #require(model.editorSession?.items.first?.id)
        let tapID = try #require(model.editorSession?.items.last?.id)

        model.selectBinding(stickID)
        model.setSelectedRadius(0.25)
        if case .joystick(_, _, _, _, _, let r) = try #require(model.editorSession?.items.first?.binding) {
            #expect(r == 0.25)
        } else { Issue.record("期待 .joystick") }
        #expect(model.editorSession?.isDirty == true)
        // 即時套用：引擎那份也要跟上
        if case .joystick(_, _, _, _, _, let r) = try #require(model.profile?.bindings.first) {
            #expect(r == 0.25)
        } else { Issue.record("期待 .joystick") }

        // 選到 tap 再調半徑：不得改到任何東西
        let snapshot = try #require(model.editorSession)
        model.selectBinding(tapID)
        model.setSelectedRadius(0.4)
        #expect(model.editorSession?.items == snapshot.items)
    }

    /// 靈敏度寫回 session 並即時套用；作用在非 look 上是 no-op。
    @Test func settingSensitivityUpdatesLookOnly() throws {
        let (store, dir) = Self.tempStore("sens")
        defer { try? FileManager.default.removeItem(at: dir) }
        let starter: [Binding] = [
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.82)),
            .look(activation: nil, sensitivity: 1.5),
        ]
        let model = AppModel(store: store, starterBindings: { starter })
        model.currentPackage = "com.game.sens"
        model.loadKeymap()
        model.toggleEditing()
        let tapID = try #require(model.editorSession?.items.first?.id)
        let lookID = try #require(model.editorSession?.items.last?.id)

        model.selectBinding(lookID)
        model.setSelectedSensitivity(3.0)
        if case .look(_, let s) = try #require(model.editorSession?.items.last?.binding) {
            #expect(s == 3.0)
        } else { Issue.record("期待 .look") }
        #expect(model.profile?.bindings.last == .look(activation: nil, sensitivity: 3.0))

        let snapshot = try #require(model.editorSession)
        model.selectBinding(tapID)
        model.setSelectedSensitivity(4.0)
        #expect(model.editorSession?.items == snapshot.items)
    }

    /// 沒有未存變更時，⌘E 直接離開——不要為了「一致」而多跳一個沒必要的對話框。
    @Test func leavingCleanSessionDoesNotPrompt() throws {
        let (store, dir) = Self.tempStore("clean-leave")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.clean"
        model.toggleEditing()

        model.toggleEditing()

        #expect(!model.pendingLeaveConfirmation)
        #expect(!model.editing)
        #expect(model.editorSession == nil)
    }

    /// 有未存變更時，⌘E **不得**離開——先問。這是資料遺失的唯一防線。
    @Test func leavingDirtySessionPromptsInsteadOfDiscarding() throws {
        let (store, dir) = Self.tempStore("dirty-leave")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.dirty"
        model.loadKeymap()
        model.toggleEditing()
        let id = try #require(model.editorSession?.items.first?.id)
        model.selectBinding(id)
        model.moveSelectedBinding(to: NormPoint(x: 0.2, y: 0.2))

        model.toggleEditing()

        #expect(model.pendingLeaveConfirmation)
        #expect(model.editing)                        // **還在編輯模式**
        #expect(model.editorSession?.isDirty == true) // 變更還在
    }

    /// 「存檔」：寫檔、離開、清提示。
    @Test func confirmLeaveSavingWritesThenLeaves() throws {
        let (store, dir) = Self.tempStore("leave-save")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.leavesave"
        model.loadKeymap()
        model.toggleEditing()
        let id = try #require(model.editorSession?.items.first?.id)
        model.selectBinding(id)
        model.moveSelectedBinding(to: NormPoint(x: 0.2, y: 0.2))
        model.toggleEditing()

        model.confirmLeaveSaving()

        #expect(!model.pendingLeaveConfirmation)
        #expect(!model.editing)
        #expect(model.editorSession == nil)
        let saved = try store.load(gameId: "com.game.leavesave")
        if case .tap(_, let at) = try #require(saved.bindings.first) {
            #expect(at == NormPoint(x: 0.2, y: 0.2))
        } else { Issue.record("期待 .tap") }
        #expect(model.profile == saved)               // 存完之後生效的是存下的那份
    }

    /// 「捨棄」：不寫檔、離開、磁碟保持空的。
    @Test func confirmLeaveDiscardingWritesNothing() throws {
        let (store, dir) = Self.tempStore("leave-discard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.discard"
        model.loadKeymap()
        model.toggleEditing()
        let id = try #require(model.editorSession?.items.first?.id)
        model.selectBinding(id)
        model.moveSelectedBinding(to: NormPoint(x: 0.2, y: 0.2))
        model.toggleEditing()

        model.confirmLeaveDiscarding()

        #expect(!model.pendingLeaveConfirmation)
        #expect(!model.editing)
        #expect(model.editorSession == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(model.profile == nil)                 // 回到磁碟的真相＝沒有 profile
        #expect(model.keymap?.hasProfile == false)    // 引擎也要清掉（C1 那條回歸）
    }

    /// 「繼續編輯」：留在編輯模式，變更原封不動。
    @Test func cancelLeaveKeepsEditingAndChanges() throws {
        let (store, dir) = Self.tempStore("leave-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8))] })
        model.currentPackage = "com.game.cancel"
        model.loadKeymap()
        model.toggleEditing()
        let id = try #require(model.editorSession?.items.first?.id)
        model.selectBinding(id)
        model.moveSelectedBinding(to: NormPoint(x: 0.2, y: 0.2))
        model.toggleEditing()

        model.cancelLeave()

        #expect(!model.pendingLeaveConfirmation)
        #expect(model.editing)
        #expect(model.editorSession?.isDirty == true)
        if case .tap(_, let at) = try #require(model.editorSession?.items.first?.binding) {
            #expect(at == NormPoint(x: 0.2, y: 0.2))
        } else { Issue.record("期待 .tap") }
    }
}
