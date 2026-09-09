import Foundation

/// ⌘E 按下之後該發生什麼。
public enum EditorEntry: Sendable, Equatable {
    /// 不動作（沒有可編的東西，也沒有 gameId 可以掛）。
    case ignore
    /// 離開編輯模式。
    case leave
    /// 進入編輯模式，帶著這份 profile（可能是既有的，也可能是剛用 starter 建出來的）。
    case enter(KeymapProfile)
}

/// ⌘E 的**純決策**。比照 `ActivationDecider`：決策與 I/O 分開，決策才測得到。
///
/// **為什麼需要它**：原本 `AppModel.toggleEditing` 的 guard 是
/// `guard editing || profile != nil else { return }`，而玩真實遊戲時 `profile` 永遠是 nil
/// （唯一的內建 profile 是佔位 gameId `com.example.game`），所以 **⌘E 完全沒有反應**。
/// 見設計文件 `docs/specs/2026-07-30-d5-keymap-editor-design.md` §1。
public enum EditorEntryDecider {
    /// - Parameters:
    ///   - editing: 目前是否已在編輯模式。
    ///   - profile: 目前作用中的 profile（`AppModel.profile`）。
    ///   - currentPackage: 偵測到的前景 package；無 adb／無前景遊戲時為 nil。
    ///   - starterBindings: 只在沒有 profile 且有 currentPackage 時求值的起始版面（見 `BuiltInProfiles.starterBindings`）。
    public static func decide(editing: Bool,
                              profile: KeymapProfile?,
                              currentPackage: String?,
                              starterBindings: @autoclosure () -> [Binding]) -> EditorEntry
    {
        // 已在編輯模式就一定放行離開——途中偵測可能把 profile 收成 nil，
        // 若這裡跟著擋掉，使用者會卡死在編輯模式出不來。
        if editing { return .leave }
        if let profile { return .enter(profile) }
        // 沒有 profile：要有 gameId 才掛得住，也要有版面才編得動。
        guard let gameId = currentPackage else { return .ignore }
        let bindings = starterBindings()
        guard !bindings.isEmpty else { return .ignore }
        return .enter(KeymapProfile(gameId: gameId, version: 1, bindings: bindings))
    }
}
