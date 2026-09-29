import Foundation

public struct InstanceEntry: Sendable, Equatable {
    public let avdName: String
    public let consolePort: Int
    public let grpcPort: Int

    public init(avdName: String, consolePort: Int, grpcPort: Int) {
        self.avdName = avdName
        self.consolePort = consolePort
        self.grpcPort = grpcPort
    }
}

public struct InstanceTableError: Error, Equatable, LocalizedError {
    public let line: Int
    public let reason: String

    public init(line: Int, reason: String) {
        self.line = line
        self.reason = reason
    }

    public var errorDescription: String? {
        "第 \(line) 行：\(reason)"
    }
}

public enum InstanceTable {
    public static func parse(_ text: String) -> Result<[InstanceEntry], InstanceTableError> {
        var entries: [InstanceEntry] = []
        var avdLines: [String: Int] = [:]
        var consoleLines: [Int: Int] = [:]
        var grpcLines: [Int: Int] = [:]

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 3 else {
                return .failure(.init(line: lineNumber, reason: "格式必須是 AVD名稱:console埠:gRPC埠"))
            }

            let avdName = String(fields[0])
            guard !avdName.isEmpty, !avdName.contains(where: { $0.isWhitespace }) else {
                return .failure(.init(line: lineNumber, reason: "實例表項目缺 AVD 名稱"))
            }

            let consolePort: Int
            switch parsePort(String(fields[1])) {
            case .success(let port): consolePort = port
            case .failure:
                return .failure(.init(line: lineNumber,
                                      reason: "\(avdName)：console 埠不是整數"))
            }
            guard (5554...5682).contains(consolePort), consolePort.isMultiple(of: 2) else {
                return .failure(.init(line: lineNumber,
                                      reason: "\(avdName)：console 埠 \(consolePort) 必須是 5554–5682 的偶數"))
            }

            let grpcPort: Int
            switch parsePort(String(fields[2])) {
            case .success(let port): grpcPort = port
            case .failure:
                return .failure(.init(line: lineNumber,
                                      reason: "\(avdName)：gRPC 埠不是整數"))
            }
            guard (1...65535).contains(grpcPort) else {
                return .failure(.init(line: lineNumber,
                                      reason: "\(avdName)：gRPC 埠 \(grpcPort) 不在 1–65535"))
            }

            if let firstLine = avdLines[avdName] {
                return .failure(.init(line: lineNumber,
                                      reason: "AVD 名稱 \(avdName) 重複（第 \(firstLine) 行已使用）"))
            }
            if let firstLine = consoleLines[consolePort] {
                return .failure(.init(line: lineNumber,
                                      reason: "console 埠 \(consolePort) 重複（第 \(firstLine) 行已使用）"))
            }
            if let firstLine = grpcLines[grpcPort] {
                return .failure(.init(line: lineNumber,
                                      reason: "gRPC 埠 \(grpcPort) 重複（第 \(firstLine) 行已使用）"))
            }

            avdLines[avdName] = lineNumber
            consoleLines[consolePort] = lineNumber
            grpcLines[grpcPort] = lineNumber
            entries.append(InstanceEntry(avdName: avdName, consolePort: consolePort, grpcPort: grpcPort))
        }

        guard !entries.isEmpty else {
            return .failure(.init(line: 1, reason: "實例表不能是空白"))
        }
        return .success(entries)
    }

    public static func bundled() -> Result<[InstanceEntry], InstanceTableError> {
        guard let url = Bundle.module.url(forResource: "instances", withExtension: "conf")
            ?? Bundle.module.url(forResource: "instances", withExtension: "conf", subdirectory: "Resources")
        else {
            return .failure(.init(line: 1, reason: "找不到內建的 Resources/instances.conf"))
        }
        do {
            return parse(try String(contentsOf: url, encoding: .utf8))
        } catch {
            return .failure(.init(line: 1, reason: "讀取內建實例表失敗：\(error.localizedDescription)"))
        }
    }

    private static func parsePort(_ raw: String) -> Result<Int, InstanceTableError> {
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = Int(raw)
        else {
            return .failure(.init(line: 1, reason: "埠必須是整數"))
        }
        return .success(port)
    }
}
