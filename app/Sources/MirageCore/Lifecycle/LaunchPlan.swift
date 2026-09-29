import Foundation

public struct LaunchPlan: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let logFile: URL
    public let environment: [String: String]

    public init(
        instance: InstanceEntry,
        sdkRoot: URL,
        homeDirectory: URL,
        environment: [String: String] = [:]
    ) {
        executable = SdkLocator(sdkRoot: sdkRoot).emulatorBinary
        arguments = [
            "-avd", instance.avdName,
            "-no-snapshot",
            "-port", String(instance.consolePort),
            "-grpc", String(instance.grpcPort),
            "-grpc-use-token",
            "-no-window",
        ]
        logFile = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Mirage", isDirectory: true)
            .appendingPathComponent("emulator-\(instance.avdName).log", isDirectory: false)
        self.environment = [
            "ANDROID_SDK_ROOT": sdkRoot.path,
            "ANDROID_AVD_HOME": MiragePaths.avdDirectory(
                environment: environment, homeDirectory: homeDirectory).path,
        ]
    }
}
