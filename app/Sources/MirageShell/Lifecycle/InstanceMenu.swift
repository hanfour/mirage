import MirageCore

/// 「切換模擬器」子選單的一列。`entry == nil` 是「沒有其他模擬器」的停用佔位。
struct InstanceMenuEntry: Equatable {
    let title: String
    let entry: InstanceEntry?
    let isCurrent: Bool
    let isRunning: Bool
    var isEnabled: Bool { entry != nil }
}

/// 子選單內容的純決策：實例表＋探索結果＋目前端點 → 列表。無 AppKit、無 I/O。
///
/// 「目前那台」只比對 gRPC 埠：探索檔（`pid_*.ini`）只描述本機實例，host 由
/// `MIRAGE_HOST` 決定且切換不改它（見 `AppModel.switchInstance`）。
enum InstanceMenu {
    static let placeholderTitle = "沒有其他模擬器"
    static let unavailableTitle = "設定完成後可切換模擬器"

    static func unavailableEntry() -> InstanceMenuEntry {
        InstanceMenuEntry(title: unavailableTitle, entry: nil, isCurrent: false, isRunning: false)
    }

    static func title(for entry: InstanceEntry, running: Bool) -> String {
        let suffix = running ? "" : "（未啟動）"
        return "\(entry.avdName)（console \(entry.consolePort)／gRPC \(entry.grpcPort)）\(suffix)"
    }

    static func entries(table: [InstanceEntry], discovered: [EmulatorInstance],
                        current: EmulatorEndpoint) -> [InstanceMenuEntry] {
        var rows = table.map { entry in
            let running = discovered.contains {
                $0.avdName == entry.avdName && $0.consolePort == entry.consolePort
            }
            return InstanceMenuEntry(title: title(for: entry, running: running), entry: entry,
                                     isCurrent: entry.grpcPort == current.port, isRunning: running)
        }

        let unlisted = discovered.filter { instance in
            !table.contains {
                $0.avdName == instance.avdName && $0.consolePort == instance.consolePort
            }
        }
        rows += unlisted.map { instance in
            let entry = InstanceEntry(avdName: instance.avdName, consolePort: instance.consolePort,
                                      grpcPort: instance.grpcPort)
            return InstanceMenuEntry(title: title(for: entry, running: true), entry: entry,
                                     isCurrent: instance.grpcPort == current.port, isRunning: true)
        }
        // 規格 §3.3：沒有**其他**實例時只剩一個停用項。只有目前那台也算沒有其他。
        guard rows.contains(where: { !$0.isCurrent }) else {
            return [InstanceMenuEntry(title: placeholderTitle, entry: nil, isCurrent: false,
                                      isRunning: false)]
        }
        return rows
    }
}
