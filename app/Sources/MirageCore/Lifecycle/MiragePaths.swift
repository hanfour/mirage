import Foundation

public enum MiragePaths {
    public static func sdkRoot(environment: [String: String], homeDirectory: URL) -> URL {
        if let value = nonEmpty(environment["ANDROID_SDK_ROOT"]) {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        if let value = nonEmpty(environment["ANDROID_HOME"]) {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Mirage", isDirectory: true)
            .appendingPathComponent("sdk", isDirectory: true)
    }

    public static func avdDirectory(environment: [String: String], homeDirectory: URL) -> URL {
        if let value = nonEmpty(environment["ANDROID_AVD_HOME"]) {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Mirage", isDirectory: true)
            .appendingPathComponent("avd", isDirectory: true)
    }

    public static func downloadsDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("Mirage", isDirectory: true)
            .appendingPathComponent("downloads", isDirectory: true)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
