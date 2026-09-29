import Foundation

public struct OwnedRecord: Codable, Equatable, Sendable {
    public let avd: String
    public let consolePort: Int
    public let pid: Int32
    public let startedAt: Date

    public init(avd: String, consolePort: Int, pid: Int32, startedAt: Date) {
        self.avd = avd
        self.consolePort = consolePort
        self.pid = pid
        self.startedAt = startedAt
    }
}

public enum OwnedInstancesReadError: Error, Equatable, Sendable, LocalizedError {
    case readFailed(String)
    case corrupted(String)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let reason): "讀取 owned instances 失敗：\(reason)"
        case .corrupted(let reason): "owned instances 格式錯誤：\(reason)"
        }
    }
}

public struct OwnedInstancesReadResult: Equatable, Sendable {
    public let records: [OwnedRecord]
    public let error: OwnedInstancesReadError?

    public init(records: [OwnedRecord], error: OwnedInstancesReadError?) {
        self.records = records
        self.error = error
    }
}

public enum OwnedInstances {
    public static func reconcile(records: [OwnedRecord], running: [EmulatorInstance]) -> [OwnedRecord] {
        records.filter { record in
            running.contains { instance in
                instance.pid == record.pid && instance.avdName == record.avd
            }
        }
    }

    public static func adding(_ record: OwnedRecord, to records: [OwnedRecord]) -> [OwnedRecord] {
        records + [record]
    }

    public static func removing(_ record: OwnedRecord, from records: [OwnedRecord]) -> [OwnedRecord] {
        var updated = records
        if let index = updated.firstIndex(of: record) {
            updated.remove(at: index)
        }
        return updated
    }

    public static func read(from url: URL) -> OwnedInstancesReadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return OwnedInstancesReadResult(records: [], error: nil)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return OwnedInstancesReadResult(records: [], error: .readFailed(error.localizedDescription))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return OwnedInstancesReadResult(records: try decoder.decode([OwnedRecord].self, from: data),
                                            error: nil)
        } catch {
            return OwnedInstancesReadResult(records: [], error: .corrupted(error.localizedDescription))
        }
    }

    public static func write(_ records: [OwnedRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)

        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}
