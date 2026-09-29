import Foundation

public struct SdkLocator: Sendable, Equatable {
    public let root: URL

    public var emulatorBinary: URL {
        root.appendingPathComponent("emulator", isDirectory: true)
            .appendingPathComponent("emulator", isDirectory: false)
    }

    public var adbBinary: URL {
        root.appendingPathComponent("platform-tools", isDirectory: true)
            .appendingPathComponent("adb", isDirectory: false)
    }

    public init(sdkRoot: URL) {
        root = sdkRoot
    }

    public init(environment: [String: String], homeDirectory: URL) {
        root = MiragePaths.sdkRoot(environment: environment, homeDirectory: homeDirectory)
    }
}
