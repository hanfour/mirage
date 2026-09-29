import Foundation
import Testing
@testable import MirageShell

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SetupStartupTests {
    @Test func prepareReturnsWhileInjectedSetupPresenterStaysOpen() async throws {
        let (store, storeDirectory) = AppModelEditingTests.tempStore("setup-nonblocking")
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let (defaults, suite) = try #require(TemporaryDefaults.make("SetupStartupTests"))
        defer { TemporaryDefaults.discard(defaults, suite) }
        let model = AppModel(
            store: store,
            launchPreferences: LaunchPreferences(defaults: defaults, environment: ["MIRAGE_BACKGROUND_MODE": "0"]),
            starterBindings: { [] })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-startup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sdkRoot = root.appendingPathComponent("sdk", isDirectory: true)
        let avdDirectory = root.appendingPathComponent("avd", isDirectory: true)
        try FileManager.default.createDirectory(at: sdkRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: avdDirectory, withIntermediateDirectories: true)
        let environment = [
            "ANDROID_SDK_ROOT": sdkRoot.path,
            "ANDROID_AVD_HOME": avdDirectory.path,
            SetupLaunchOptions.availableBytesKey: "100000000000",
        ]
        let presenter = SetupPresenterRecorder()
        let preparation = Task { @MainActor in
            await model.prepareInstanceLauncher(
                environment: environment,
                discoverInstances: { [] },
                presentSetup: { controller, _ in presenter.record(controller) })
        }

        let outcome = await awaitWithWatchdog(.seconds(2)) {
            await preparation.value
            return SetupStartupSignal.returned
        }

        #expect(outcome == .finished(.returned))
        #expect(presenter.presentations == 1)
        #expect(presenter.controller != nil)
        #expect(model.instanceManagerPresentation.setupVisible)
        #expect(model.instanceManagerPresentation.launcher == nil)
        #expect(model.setupWindowController == nil)
    }
}

@MainActor
private final class SetupPresenterRecorder {
    private(set) var presentations = 0
    private(set) var controller: SetupController?

    func record(_ controller: SetupController) {
        presentations += 1
        self.controller = controller
    }
}

private enum SetupStartupSignal: Equatable, Sendable {
    case returned
}
