import Foundation

/// 編輯階段的 binding 清單與選取狀態。**不可變值型別**：所有變換回傳新的 session。
///
/// **為什麼身分留在這裡、不寫進 JSON**（設計文件 §3.1）：`Binding` 是裸 enum 存在陣列裡，
/// 而編輯器要選取與刪除，用陣列索引當身分必壞——刪掉第 1 筆，第 2 筆的索引變成 1，
/// 選取就跳到錯的東西上。身分是**編輯階段的概念**，不是 profile 的屬性；
/// 寫進 JSON 只會多一套版本遷移，換不到任何東西。
///
/// **刻意不提供重排**（§3.2）：`KeymapEngine` 對 joystick/look 採一對一 id 模型，觸點
/// identifier 由**陣列順序**決定。重排會改變送給 guest 的 identifier，要支援得連引擎的
/// id 模型一起重新設計。
public struct EditorSession: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public let id: UUID
        public var binding: Binding
    }

    public private(set) var items: [Item]
    public private(set) var selectedID: UUID?
    /// 有沒有**實際改過資料**。選取不算——否則使用者點一下清單，離開時就會被問要不要存檔。
    public private(set) var isDirty: Bool
    public private(set) var rebindingID: UUID?
    public let gameId: String
    private let baseVersion: Int

    public init(profile: KeymapProfile) {
        items = profile.bindings.map { Item(id: UUID(), binding: $0) }
        selectedID = nil
        isDirty = false
        rebindingID = nil
        gameId = profile.gameId
        baseVersion = profile.version
    }

    public func selecting(_ id: UUID?) -> EditorSession {
        var copy = self
        copy.selectedID = id
        if copy.rebindingID != id { copy.rebindingID = nil }
        return copy                     // isDirty 不動：選取不是變更
    }

    public func movingSelected(to p: NormPoint) -> EditorSession {
        mutatingSelected { binding in
            switch binding {
            case .tap(let key, _, let gamepad):
                return .tap(key: key, at: p, gamepad: gamepad)
            case .joystick(let u, let d, let l, let r, _, let radius):
                return .joystick(up: u, down: d, left: l, right: r, center: p, radius: radius)
            case .look:
                // 視角不是螢幕上的一個點——沒有位置可移。回 nil 表示「沒有改變」，
                // 呼叫端因此也不會被標記為髒（見 `mutatingSelected`）。
                return nil
            }
        }
    }

    public func settingSelectedRadius(_ r: Double) -> EditorSession {
        mutatingSelected { binding in
            guard case .joystick(let u, let d, let l, let ri, let c, _) = binding else { return nil }
            return .joystick(up: u, down: d, left: l, right: ri, center: c, radius: r)
        }
    }

    public func settingSelectedSensitivity(_ s: Double) -> EditorSession {
        mutatingSelected { binding in
            guard case .look(let activation, _) = binding else { return nil }
            return .look(activation: activation, sensitivity: s)
        }
    }

    public func addingTap(at point: NormPoint) -> EditorSession {
        var copy = self
        let item = Item(id: UUID(), binding: .tap(key: .key("Unbound"), at: point))
        copy.items.append(item)
        copy.selectedID = item.id
        copy.rebindingID = item.id
        copy.isDirty = true
        return copy
    }

    public func deletingSelected() -> EditorSession {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else { return self }
        var copy = self
        copy.items.remove(at: index)
        copy.selectedID = nil
        copy.rebindingID = nil
        copy.isDirty = true
        return copy
    }

    public func beginningRebindSelected() -> EditorSession {
        guard let selectedID,
              items.contains(where: { $0.id == selectedID && isTap($0.binding) })
        else { return self }
        var copy = self
        copy.rebindingID = selectedID
        return copy
    }

    public func cancelRebinding() -> EditorSession {
        guard rebindingID != nil else { return self }
        var copy = self
        copy.rebindingID = nil
        return copy
    }

    public func capturingKeyboardKey(_ key: KeyCode) -> EditorSession {
        guard let rebindingID else { return self }
        return mutatingItem(id: rebindingID, transform: { binding in
            guard case .tap(_, let point, let gamepad) = binding else { return nil }
            return .tap(key: key, at: point, gamepad: gamepad)
        })
    }

    public func capturingGamepadButton(_ button: GamepadButton) -> EditorSession {
        guard let rebindingID else { return self }
        return mutatingItem(id: rebindingID, transform: { binding in
            guard case .tap(let key, let point, _) = binding else { return nil }
            return .tap(key: key, at: point, gamepad: button)
        })
    }

    public func clearingSelectedGamepadButton() -> EditorSession {
        mutatingSelected { binding in
            guard case .tap(let key, let point, let gamepad) = binding, gamepad != nil else { return nil }
            return .tap(key: key, at: point, gamepad: nil)
        }
    }

    public var canSave: Bool {
        items.allSatisfy { item in
            guard case .tap(let key, _, _) = item.binding else { return true }
            return key != .key("Unbound")
        }
    }

    /// 存檔用。`gameId` 沿用建構時那份、`version` 加一、順序與內容照 `items`。
    public func profile() -> KeymapProfile {
        KeymapProfile(gameId: gameId, version: baseVersion + 1, bindings: items.map(\.binding))
    }

    /// 對選中的那一筆套用 `transform`。`transform` 回 nil 代表「這種 binding 不吃這個操作」
    /// ——此時整個 session 原封不動，**包含 `isDirty`**。把「不適用」與「改了」分開，
    /// 是為了不讓「選到視角、隨手拖一下」變成一筆假的未存變更。
    private func mutatingSelected(_ transform: (Binding) -> Binding?) -> EditorSession {
        guard let selectedID,
              let index = items.firstIndex(where: { $0.id == selectedID }),
              let updated = transform(items[index].binding),
              updated != items[index].binding
        else { return self }

        var copy = self
        copy.items[index].binding = updated
        copy.isDirty = true
        return copy
    }

    private func mutatingItem(id: UUID, transform: (Binding) -> Binding?) -> EditorSession {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let updated = transform(items[index].binding)
        else { return self }
        var copy = self
        if updated != items[index].binding {
            copy.items[index].binding = updated
            copy.isDirty = true
        }
        copy.rebindingID = nil
        return copy
    }

    private func isTap(_ binding: Binding) -> Bool {
        if case .tap = binding { return true }
        return false
    }
}
