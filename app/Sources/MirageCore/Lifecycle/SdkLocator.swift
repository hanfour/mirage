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
        if let sdkRoot = environment["ANDROID_SDK_ROOT"], !sdkRoot.isEmpty {
            root = URL(fileURLWithPath: sdkRoot, isDirectory: true)
        } else if let androidHome = environment["ANDROID_HOME"], !androidHome.isEmpty {
            root = URL(fileURLWithPath: androidHome, isDirectory: true)
        } else {
            root = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Android", isDirectory: true)
                .appendingPathComponent("sdk", isDirectory: true)
        }
    }
}
