import Foundation

/// 測試用暫存目錄：每個測試 suite 實例持有一份，測試結束 suite 釋放時刪掉它建立的所有目錄。
///
/// swift-testing 每條測試都建立新的 suite 實例，所以 `deinit` 等於每條測試結束後清理，
/// 不需要在每條測試裡各寫一次 `defer`。原本這幾組測試建了目錄從來不刪，每跑一次 CI
/// 在系統暫存目錄留下約 60 個，累積到上千個（2026-10-02 清掉 1888 個）。
/// 目錄名一律用 UUID：物件位址當後綴會被重用，兩條測試可能拿到同一個目錄。
final class ScratchDirectories: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [URL] = []

    func make(_ prefix: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lock.lock(); created.append(directory); lock.unlock()
        return directory
    }

    deinit {
        for directory in created { try? FileManager.default.removeItem(at: directory) }
    }
}
