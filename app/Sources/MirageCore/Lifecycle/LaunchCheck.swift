import Foundation

public enum LaunchCheck {
    public static func failure(
        instance: InstanceEntry,
        sdkRoot: URL,
        environment: [String: String],
        homeDirectory: URL,
        running: [EmulatorInstance],
        fileExists: (URL) -> Bool
    ) -> InstanceFailure? {
        let emulator = SdkLocator(sdkRoot: sdkRoot).emulatorBinary
        guard fileExists(emulator) else {
            return .emulatorNotFound(emulator)
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
            return .avdNotFound(avdConfiguration)
        }

        if let conflict = running.first(where: {
            $0.avdName == instance.avdName && $0.consolePort != instance.consolePort
        }) {
            return .avdInUse(consolePort: conflict.consolePort)
        }
        return nil
    }
}
