import Foundation

public enum LaunchCheckFailure: Sendable, Equatable {
    case emulatorBinaryNotFound(URL)
    case avdConfigurationNotFound(URL)
    case avdAlreadyRunning(consolePort: Int)
}

public enum LaunchCheck {
    public static func failure(
        instance: InstanceEntry,
        sdkRoot: URL,
        environment: [String: String],
        homeDirectory: URL,
        running: [EmulatorInstance],
        fileExists: (URL) -> Bool
    ) -> LaunchCheckFailure? {
        let emulator = SdkLocator(sdkRoot: sdkRoot).emulatorBinary
        guard fileExists(emulator) else {
            return .emulatorBinaryNotFound(emulator)
        }

        let avdDirectory: URL
        if let override = environment["ANDROID_AVD_HOME"], !override.isEmpty {
            avdDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            avdDirectory = homeDirectory
                .appendingPathComponent(".android", isDirectory: true)
                .appendingPathComponent("avd", isDirectory: true)
        }
        let avdConfiguration = avdDirectory.appendingPathComponent(
            "\(instance.avdName).ini", isDirectory: false)
        guard fileExists(avdConfiguration) else {
            return .avdConfigurationNotFound(avdConfiguration)
        }

        if let conflict = running.first(where: {
            $0.avdName == instance.avdName && $0.consolePort != instance.consolePort
        }) {
            return .avdAlreadyRunning(consolePort: conflict.consolePort)
        }
        return nil
    }
}
