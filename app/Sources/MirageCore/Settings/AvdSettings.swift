import Foundation

public enum AvdSettings {
    public struct Resolution: Hashable, Sendable {
        public let width: Int
        public let height: Int
        public let density: Int

        public init(width: Int, height: Int, density: Int) {
            self.width = width
            self.height = height
            self.density = density
        }

        public var description: String { "\(width)x\(height)@\(density)" }
        public var menuTitle: String { "\(width) × \(height) @ \(density) dpi" }
    }

    public struct Values: Hashable, Sendable {
        public var cores: Int
        public var ramMB: Int
        public var resolution: Resolution

        public init(cores: Int, ramMB: Int, resolution: Resolution) {
            self.cores = cores
            self.ramMB = ramMB
            self.resolution = resolution
        }
    }

    public struct Options: Equatable, Sendable {
        public let cores: [Int]
        public let ramMB: [Int]
        public let resolutions: [Resolution]
    }

    public enum ConfigError: Error, Equatable, LocalizedError, Sendable {
        case missingOrInvalidValue(String)

        public var errorDescription: String? {
            switch self {
            case .missingOrInvalidValue(let key): "config.ini 缺少有效欄位：\(key)"
            }
        }
    }

    public enum AutoApplyError: Error, Equatable, LocalizedError, Sendable {
        case invalidField(String)
        case duplicateField(String)
        case missingField(String)
        case invalidValue(String)

        public var errorDescription: String? {
            switch self {
            case .invalidField(let field): "欄位格式無效：\(field)"
            case .duplicateField(let field): "欄位重複：\(field)"
            case .missingField(let field): "缺少欄位：\(field)"
            case .invalidValue(let value): "值無效：\(value)"
            }
        }
    }

    public static let managedMarkerFilename = ".mirage-managed"
    public static let managedMarkerContent = "由 Mirage 設定精靈建立\n"

    private static let coresKey = "hw.cpu.ncore"
    private static let ramKey = "hw.ramSize"
    private static let widthKey = "hw.lcd.width"
    private static let heightKey = "hw.lcd.height"
    private static let densityKey = "hw.lcd.density"
    private static let orderedKeys = [coresKey, ramKey, widthKey, heightKey, densityKey]
    private static let coreOptions = [2, 4, 6, 8]
    private static let ramOptions = [2048, 3072, 4096, 6144, 8192]
    private static let resolutionOptions = [
        Resolution(width: 720, height: 1600, density: 280),
        Resolution(width: 1080, height: 2400, density: 420),
        Resolution(width: 1440, height: 3200, density: 560),
    ]
    private static let autoApplyKeys = ["cores", "ramMB", "resolution"]
    private static let bytesPerMB: UInt64 = 1_048_576

    public static func options(hostProcessorCount: Int, hostMemoryBytes: UInt64) -> Options {
        let maximumRAMMB = hostMemoryBytes / 2 / bytesPerMB
        return Options(
            cores: coreOptions.filter { $0 <= hostProcessorCount },
            ramMB: ramOptions.filter { UInt64($0) <= maximumRAMMB },
            resolutions: resolutionOptions)
    }

    public static func parseConfig(_ text: String) throws -> Values {
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }

        func integer(_ key: String) throws -> Int {
            guard let value = values[key], let parsed = Int(value) else {
                throw ConfigError.missingOrInvalidValue(key)
            }
            return parsed
        }

        return Values(
            cores: try integer(coresKey),
            ramMB: try integer(ramKey),
            resolution: Resolution(width: try integer(widthKey),
                                   height: try integer(heightKey),
                                   density: try integer(densityKey)))
    }

    public static func updatedConfig(original: String, settings: Values) -> String {
        let replacements = replacementValues(settings)
        var pending = Set(orderedKeys)
        var output = ""

        for (line, terminator) in splitLines(original) {
            let updatedLine: String
            if let key = configKey(in: line), let replacement = replacements[key] {
                updatedLine = replacingValue(in: line, with: replacement)
                pending.remove(key)
            } else {
                updatedLine = line
            }
            output += updatedLine + terminator
        }

        if !pending.isEmpty {
            if !output.isEmpty, !output.hasSuffix("\n"), !output.hasSuffix("\r") {
                output += "\n"
            }
            for key in orderedKeys where pending.contains(key) {
                output += "\(key) = \(replacements[key]!)\n"
            }
        }
        return output
    }

    public static func isManaged(at avdDirectory: URL,
                                 fileManager: FileManager = .default) -> Bool {
        // 開發機的 AVD 是量測環境，由 provision.py 依 sdk-spec.json 管理；app 改它會造成
        // provision 報漂移，讓量測環境跑掉。
        let marker = avdDirectory.appendingPathComponent(managedMarkerFilename, isDirectory: false)
        return fileManager.fileExists(atPath: marker.path)
    }

    public static func parseAutoApply(
        _ input: String,
        hostProcessorCount: Int,
        hostMemoryBytes: UInt64
    ) -> Result<Values, AutoApplyError> {
        var fields: [String: String] = [:]
        for component in input.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return .failure(.invalidField(String(component))) }
            let key = String(pair[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard autoApplyKeys.contains(key), !value.isEmpty else {
                return .failure(.invalidField(String(component)))
            }
            guard fields[key] == nil else { return .failure(.duplicateField(key)) }
            fields[key] = value
        }
        for key in autoApplyKeys where fields[key] == nil {
            return .failure(.missingField(key))
        }

        guard let coresText = fields[autoApplyKeys[0]], let cores = Int(coresText),
              options(hostProcessorCount: hostProcessorCount, hostMemoryBytes: hostMemoryBytes)
                .cores.contains(cores) else {
            return .failure(.invalidValue(fields[autoApplyKeys[0]] ?? ""))
        }
        guard let ramText = fields[autoApplyKeys[1]], let ramMB = Int(ramText),
              options(hostProcessorCount: hostProcessorCount, hostMemoryBytes: hostMemoryBytes)
                .ramMB.contains(ramMB) else {
            return .failure(.invalidValue(fields[autoApplyKeys[1]] ?? ""))
        }
        guard let resolutionText = fields[autoApplyKeys[2]],
              let resolution = resolutionOptions.first(where: {
                  "\($0.width)x\($0.height)" == resolutionText
              }) else {
            return .failure(.invalidValue(fields[autoApplyKeys[2]] ?? ""))
        }
        return .success(Values(cores: cores, ramMB: ramMB, resolution: resolution))
    }

    public static func coreChoiceLabel(_ value: Int, options: [Int]) -> String {
        options.contains(value) ? "\(value)" : "自訂：\(value)"
    }

    public static func ramChoiceLabel(_ value: Int, options: [Int]) -> String {
        options.contains(value) ? "\(value) MB" : "自訂：\(value) MB"
    }

    public static func resolutionChoiceLabel(_ value: Resolution, options: [Resolution]) -> String {
        options.contains(value) ? value.menuTitle : "自訂：\(value.description)"
    }

    private static func replacementValues(_ settings: Values) -> [String: String] {
        [
            coresKey: String(settings.cores),
            ramKey: String(settings.ramMB),
            widthKey: String(settings.resolution.width),
            heightKey: String(settings.resolution.height),
            densityKey: String(settings.resolution.density),
        ]
    }

    private static func splitLines(_ text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var line = ""
        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                result.append((line, String(character)))
                line = ""
            } else {
                line.append(character)
            }
        }
        if !line.isEmpty || result.isEmpty { result.append((line, "")) }
        return result
    }

    private static func configKey(in line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#"),
              let separator = line.firstIndex(of: "=") else { return nil }
        return String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingValue(in line: String, with value: String) -> String {
        guard let separator = line.firstIndex(of: "=") else { return line }
        let prefix = line[...separator]
        let oldValue = line[line.index(after: separator)...]
        let leadingCount = oldValue.prefix { $0.isWhitespace }.count
        let trailingCount = oldValue.reversed().prefix { $0.isWhitespace }.count
        let leading = oldValue.prefix(leadingCount)
        let trailing = trailingCount == 0 ? "" : String(oldValue.suffix(trailingCount))
        return String(prefix) + String(leading) + value + trailing
    }
}
