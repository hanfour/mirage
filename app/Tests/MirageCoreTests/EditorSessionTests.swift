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
        if case .tap(let key, let at) = moved.items[1].binding {
            #expect(key == .key("j"))                 // 鍵沒被動到
            #expect(at == NormPoint(x: 0.1, y: 0.2))
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

    /// 存檔用的 profile：gameId 沿用、version+1、順序與內容照 items。
    @Test func profileBumpsVersionAndKeepsGameIdAndOrder() {
        let base = EditorSession(profile: sample())
        let edited = base.selecting(base.items[1].id).movingSelected(to: NormPoint(x: 0.1, y: 0.2))
        let p = edited.profile()
        #expect(p.gameId == "com.game.a")
        #expect(p.version == 4)                       // 3 + 1
        #expect(p.bindings == edited.items.map(\.binding))
        #expect(try! p.validated() == p)              // 產出的 profile 必須是合法的
    }

    /// 產出的 profile 能再餵回 session，形成可重複的編輯循環。
    @Test func profileRoundTripsBackIntoASession() {
        let base = EditorSession(profile: sample())
        let again = EditorSession(profile: base.profile())
        #expect(again.items.map(\.binding) == base.items.map(\.binding))
        #expect(!again.isDirty)
        #expect(again.selectedID == nil)              // 新 session 從未選取起算
    }
}
