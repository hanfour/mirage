import Foundation

final class ScratchDirectories: @unchecked Sendable {
    private let lock = NSLock()
    private var created: [URL] = []

    func make(_ prefix: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lock.lock()
        created.append(directory)
        lock.unlock()
        return directory
    }

    deinit {
        for directory in created {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
