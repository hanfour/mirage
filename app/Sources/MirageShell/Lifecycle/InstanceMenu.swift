import MirageCore

/// 「切換模擬器」子選單的一列。`instance == nil` 是「沒有其他模擬器」的停用佔位。
struct InstanceMenuEntry: Equatable {
    let title: String
    let instance: EmulatorInstance?
    let isCurrent: Bool
    var isEnabled: Bool { instance != nil }
}

/// 子選單內容的純決策：實例清單＋目前端點 → 列表。無 AppKit、無 I/O，逐條單元測試。
///
/// 「目前那台」只比對 gRPC 埠：探索檔（`pid_*.ini`）只描述本機實例，host 由
/// `MIRAGE_HOST` 決定且切換不改它（見 `AppModel.switchInstance`）。
enum InstanceMenu {
    static let placeholderTitle = "沒有其他模擬器"

    static func title(for instance: EmulatorInstance) -> String {
        "\(instance.avdName)（console \(instance.consolePort)／gRPC \(instance.grpcPort)）"
    }

    static func entries(instances: [EmulatorInstance], current: EmulatorEndpoint) -> [InstanceMenuEntry] {
        let rows = instances.map { instance in
            InstanceMenuEntry(title: title(for: instance), instance: instance,
                              isCurrent: instance.grpcPort == current.port)
        }
        // 規格 §3.3：沒有**其他**實例時只剩一個停用項。只有目前那台也算沒有其他。
        guard rows.contains(where: { !$0.isCurrent }) else {
            return [InstanceMenuEntry(title: placeholderTitle, instance: nil, isCurrent: false)]
        }
        return rows
    }
}
