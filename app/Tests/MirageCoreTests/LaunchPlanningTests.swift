import Foundation
import Testing
@testable import MirageCore

@Suite("SdkLocator")
struct SdkLocatorTests {
    private let home = URL(fileURLWithPath: "/users/tester", isDirectory: true)

    @Test func sdkRootHasHighestPriority() {
        let locator = SdkLocator(
            environment: ["ANDROID_SDK_ROOT": "/sdk-root", "ANDROID_HOME": "/android-home"],
            homeDirectory: home)
        #expect(locator.root.path == "/sdk-root")
    }

    @Test func androidHomeIsUsedWhenSdkRootIsAbsent() {
        let locator = SdkLocator(environment: ["ANDROID_HOME": "/android-home"], homeDirectory: home)
        #expect(locator.root.path == "/android-home")
    }

    @Test func emptySdkRootFallsThroughToAndroidHome() {
        let locator = SdkLocator(
            environment: ["ANDROID_SDK_ROOT": "", "ANDROID_HOME": "/android-home"],
            homeDirectory: home)
        #expect(locator.root.path == "/android-home")
    }

    @Test func emptySdkVariablesFallBackToHomeDirectory() {
        let locator = SdkLocator(
            environment: ["ANDROID_SDK_ROOT": "", "ANDROID_HOME": ""],
            homeDirectory: home)
        #expect(locator.root.path == "/users/tester/Library/Android/sdk")
    }

    @Test func exposesEmulatorAndAdbBinaries() {
        let locator = SdkLocator(environment: [:], homeDirectory: home)
        #expect(locator.emulatorBinary.path == "/users/tester/Library/Android/sdk/emulator/emulator")
        #expect(locator.adbBinary.path == "/users/tester/Library/Android/sdk/platform-tools/adb")
    }
}

@Suite("LaunchPlan")
struct LaunchPlanTests {
    @Test func containsExactHeadlessArgumentsAndLogPath() {
        let instance = InstanceEntry(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554)
        let plan = LaunchPlan(
            instance: instance,
            sdkRoot: URL(fileURLWithPath: "/sdk", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/users/tester", isDirectory: true))

        #expect(plan.executable.path == "/sdk/emulator/emulator")
        #expect(plan.arguments == [
            "-avd", "mirage-game",
            "-no-snapshot",
            "-port", "5554",
            "-grpc", "8554",
            "-grpc-use-token",
            "-no-window",
        ])
        #expect(plan.logFile.path == "/users/tester/Library/Logs/Mirage/emulator-mirage-game.log")
    }
}

@Suite("LaunchCheck")
struct LaunchCheckTests {
    private let instance = InstanceEntry(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554)
    private let sdkRoot = URL(fileURLWithPath: "/sdk", isDirectory: true)
    private let home = URL(fileURLWithPath: "/users/tester", isDirectory: true)

    private var emulator: URL {
        sdkRoot.appendingPathComponent("emulator", isDirectory: true)
            .appendingPathComponent("emulator", isDirectory: false)
    }

    @Test func reportsMissingEmulatorBeforeOtherFailures() {
        let failure = check(running: [otherConsole]) { _ in false }
        #expect(failure == .emulatorBinaryNotFound(emulator))
    }

    @Test func reportsMissingAvdConfigurationBeforeConflict() {
        let failure = check(running: [otherConsole]) { $0 == emulator }
        let expected = URL(fileURLWithPath: "/users/tester/.android/avd/mirage-game.ini")
        #expect(failure == .avdConfigurationNotFound(expected))
    }

    @Test func usesAndroidAvdHomeOverride() {
        var checked: [String] = []
        let failure = check(environment: ["ANDROID_AVD_HOME": "/custom/avds"], running: []) {
            checked.append($0.path)
            return true
        }
        #expect(failure == nil)
        #expect(checked == [
            emulator.path,
            "/custom/avds/mirage-game.ini",
        ])
    }

    @Test func reportsSameAvdOnAnotherConsole() {
        let failure = check(running: [otherConsole]) { _ in true }
        #expect(failure == .avdAlreadyRunning(consolePort: 5556))
    }

    @Test func sameAvdOnRequestedConsoleIsAllowed() {
        let current = EmulatorInstance(avdName: "mirage-game", consolePort: 5554,
                                       grpcPort: 8554, pid: 123)
        let failure = check(running: [current]) { _ in true }
        #expect(failure == nil)
    }

    private var otherConsole: EmulatorInstance {
        EmulatorInstance(avdName: "mirage-game", consolePort: 5556, grpcPort: 8556, pid: 456)
    }

    private func check(
        environment: [String: String] = [:],
        running: [EmulatorInstance],
        fileExists: (URL) -> Bool
    ) -> LaunchCheckFailure? {
        LaunchCheck.failure(instance: instance, sdkRoot: sdkRoot, environment: environment,
                            homeDirectory: home, running: running, fileExists: fileExists)
    }
}
