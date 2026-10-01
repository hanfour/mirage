import Testing
@testable import MirageCore

@Suite struct EditorSessionTests {
    private func sample() -> KeymapProfile {
        KeymapProfile(gameId: "com.game.a", version: 3, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.12),
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.82)),
            .look(activation: nil, sensitivity: 1.5),
        ])
    }

    /// 建構時每個 binding 拿到一個穩定身分，順序照舊（順序決定 touch identifier）。
    @Test func initAssignsStableIdentityAndKeepsOrder() {
        let s = EditorSession(profile: sample())
        #expect(s.items.count == 3)
        #expect(s.items.map(\.binding) == sample().bindings)
        #expect(Set(s.items.map(\.id)).count == 3)   // 身分互不相同
        #expect(s.selectedID == nil)
        #expect(!s.isDirty)
        #expect(s.gameId == "com.game.a")
    }

    /// 選取不算變更——否則點一下清單，離開時就會被問要不要存檔。
    @Test func selectingDoesNotMarkDirty() {
        let s = EditorSession(profile: sample())
        let picked = s.selecting(s.items[1].id)
        #expect(picked.selectedID == s.items[1].id)
        #expect(!picked.isDirty)
        #expect(picked.items == s.items)
    }

    /// 移動選中的 tap：只有那一筆改變，其餘原封不動，且標記為髒。
    @Test func movingSelectedTapChangesOnlyThatBinding() {
        let s = EditorSession(profile: sample()).selecting(EditorSession(profile: sample()).items[1].id)
        let target = s.items[1].id
        let moved = s.selecting(target).movingSelected(to: NormPoint(x: 0.1, y: 0.2))
        #expect(moved.isDirty)
        if case .tap(let key, let at, let gamepad) = moved.items[1].binding {
            #expect(key == .key("j"))                 // 鍵沒被動到
            #expect(at == NormPoint(x: 0.1, y: 0.2))
            #expect(gamepad == nil)
        } else {
            Issue.record("期待 .tap，實得 \(moved.items[1].binding)")
        }
        #expect(moved.items[0].binding == s.items[0].binding)
        #expect(moved.items[2].binding == s.items[2].binding)
        #expect(moved.items.map(\.id) == s.items.map(\.id))   // 身分不隨變換改變
    }

    /// 移動選中的搖桿改的是圓心，半徑與四顆鍵都不動。
    @Test func movingSelectedJoystickMovesCentreOnly() {
        let base = EditorSession(profile: sample())
        let moved = base.selecting(base.items[0].id).movingSelected(to: NormPoint(x: 0.4, y: 0.4))
        if case .joystick(let u, _, _, _, let c, let r) = moved.items[0].binding {
            #expect(u == .key("w"))
            #expect(c == NormPoint(x: 0.4, y: 0.4))
            #expect(r == 0.12)
        } else {
            Issue.record("期待 .joystick，實得 \(moved.items[0].binding)")
        }
    }

    /// `.look` 沒有位置可移——移動它必須是 no-op，且**不得**標記為髒
    /// （否則使用者選到視角、隨手拖一下，離開時就被問要不要存一個什麼都沒改的變更）。
    @Test func movingSelectedLookIsNoOp() {
        let base = EditorSession(profile: sample())
        let moved = base.selecting(base.items[2].id).movingSelected(to: NormPoint(x: 0.4, y: 0.4))
        #expect(moved.items == base.items)
        #expect(!moved.isDirty)
    }

    /// 沒有選取時，任何變換都是 no-op。
    @Test func mutationsWithoutSelectionAreNoOps() {
        let base = EditorSession(profile: sample())
        #expect(base.movingSelected(to: NormPoint(x: 0.4, y: 0.4)).items == base.items)
        #expect(!base.movingSelected(to: NormPoint(x: 0.4, y: 0.4)).isDirty)
        #expect(base.settingSelectedRadius(0.3).items == base.items)
        #expect(base.settingSelectedSensitivity(2.0).items == base.items)
    }

    /// 半徑只作用在搖桿上；作用在 tap 上是 no-op。
    @Test func settingRadiusAppliesOnlyToJoystick() {
        let base = EditorSession(profile: sample())
        let widened = base.selecting(base.items[0].id).settingSelectedRadius(0.3)
        if case .joystick(_, _, _, _, _, let r) = widened.items[0].binding { #expect(r == 0.3) }
        else { Issue.record("期待 .joystick") }
        #expect(widened.isDirty)

        let onTap = base.selecting(base.items[1].id).settingSelectedRadius(0.3)
        #expect(onTap.items == base.items)
        #expect(!onTap.isDirty)
    }

    /// 靈敏度只作用在 look 上；作用在搖桿上是 no-op。
    @Test func settingSensitivityAppliesOnlyToLook() {
        let base = EditorSession(profile: sample())
        let faster = base.selecting(base.items[2].id).settingSelectedSensitivity(2.5)
        if case .look(let act, let s) = faster.items[2].binding {
            #expect(act == nil)
            #expect(s == 2.5)
        } else { Issue.record("期待 .look") }
        #expect(faster.isDirty)

        let onStick = base.selecting(base.items[0].id).settingSelectedSensitivity(2.5)
        #expect(onStick.items == base.items)
        #expect(!onStick.isDirty)
    }

    /// 規則 (c)：變換算出與原值**相同**的 binding 時不得設髒。
    ///
    /// 這是「拖了一下又拖回原位」「滑桿拉回原值」之後，離開時不該被問「要不要存檔」的保證。
    /// 少了它會產生假的未存變更提示，而假提示會訓練使用者無視提示。
    @Test func mutationsToTheSameValueDoNotMarkDirty() {
        let base = EditorSession(profile: sample())

        // tap 移到它原本就在的位置（sample() 的 .tap 座標 0.85, 0.82）
        let tapSame = base.selecting(base.items[1].id)
            .movingSelected(to: NormPoint(x: 0.85, y: 0.82))
        #expect(!tapSame.isDirty)
        #expect(tapSame.items == base.items)

        // joystick 設成它原本的半徑（sample() 的 .joystick radius 0.12）
        let stickSame = base.selecting(base.items[0].id).settingSelectedRadius(0.12)
        #expect(!stickSame.isDirty)
        #expect(stickSame.items == base.items)

        // look 設成它原本的靈敏度（sample() 的 .look sensitivity 1.5）
        let lookSame = base.selecting(base.items[2].id).settingSelectedSensitivity(1.5)
        #expect(!lookSame.isDirty)
        #expect(lookSame.items == base.items)
    }

    /// 存檔用的 profile：gameId 沿用、version+1、順序與內容照 items。
    ///
    /// 標成 `throws` 而不是 `try!`（M4，D5 階段 B 終審）：`try!` 讓一條斷言失敗從「一條紅」
    /// 升級成整個 test run 帶著 SIGILL 死掉，而錯誤訊息完全不指向成因。
    @Test func profileBumpsVersionAndKeepsGameIdAndOrder() throws {
        let base = EditorSession(profile: sample())
        let edited = base.selecting(base.items[1].id).movingSelected(to: NormPoint(x: 0.1, y: 0.2))
        let p = edited.profile()
        #expect(p.gameId == "com.game.a")
        #expect(p.version == 4)                       // 3 + 1
        #expect(p.bindings == edited.items.map(\.binding))
        #expect(try p.validated() == p)               // 產出的 profile 必須是合法的
    }

    /// 產出的 profile 能再餵回 session，形成可重複的編輯循環。
    @Test func profileRoundTripsBackIntoASession() {
        let base = EditorSession(profile: sample())
        let again = EditorSession(profile: base.profile())
        #expect(again.items.map(\.binding) == base.items.map(\.binding))
        #expect(!again.isDirty)
        #expect(again.selectedID == nil)              // 新 session 從未選取起算
    }

    @Test func addingAndDeletingTapPreservesOtherBindingOrder() throws {
        let base = EditorSession(profile: sample())
        let originalIDs = base.items.map(\.id)
        let removedMiddle = base.selecting(originalIDs[1]).deletingSelected()
        #expect(removedMiddle.items.map(\.id) == [originalIDs[0], originalIDs[2]])

        let added = base.addingTap(at: NormPoint(x: 0.5, y: 0.5))
        #expect(added.items.map(\.id).prefix(3).elementsEqual(originalIDs))
        #expect(added.items.count == 4)
        #expect(added.selectedID == added.items.last?.id)
        #expect(added.rebindingID == added.selectedID)
        #expect(!added.canSave)

        let removed = added.deletingSelected()
        #expect(removed.items.map(\.id) == originalIDs)
        #expect(removed.items.map(\.binding) == base.items.map(\.binding))
        #expect(removed.selectedID == nil)
    }

    @Test func capturesKeyboardAndGamepadKeysAndSupportsEscapeAndClear() throws {
        let base = EditorSession(profile: sample())
        let tapID = base.items[1].id
        let keyboard = base.selecting(tapID).beginningRebindSelected()
            .capturingKeyboardKey(.key("q"))
        #expect(keyboard.rebindingID == nil)
        guard case .tap(let key, _, let gamepad) = keyboard.items[1].binding else {
            Issue.record("期待 .tap")
            return
        }
        #expect(key == .key("q"))
        #expect(gamepad == nil)

        let gamepad = keyboard.beginningRebindSelected().capturingGamepadButton(.rightShoulder)
        guard case .tap(let reboundKey, _, let button) = gamepad.items[1].binding else {
            Issue.record("期待 .tap")
            return
        }
        #expect(reboundKey == .key("q"))
        #expect(button == .rightShoulder)

        let cancelled = gamepad.beginningRebindSelected().cancelRebinding()
        #expect(cancelled.rebindingID == nil)
        #expect(cancelled.items == gamepad.items)
        let cleared = gamepad.clearingSelectedGamepadButton()
        guard case .tap(_, _, let clearedButton) = cleared.items[1].binding else {
            Issue.record("期待 .tap")
            return
        }
        #expect(clearedButton == nil)
        #expect(cleared.isDirty)
    }

    @Test func capturesNewTapKeyboardKeyAndMarksItSaveable() throws {
        let added = EditorSession(profile: KeymapProfile(gameId: "g", version: 1, bindings: []))
            .addingTap(at: NormPoint(x: 0.5, y: 0.5))
        let captured = added.capturingKeyboardKey(.key("r"))
        #expect(captured.canSave)
        #expect(captured.isDirty)
        guard case .tap(let key, _, _) = try #require(captured.items.first).binding else {
            Issue.record("期待 .tap")
            return
        }
        #expect(key == .key("r"))
    }
}
