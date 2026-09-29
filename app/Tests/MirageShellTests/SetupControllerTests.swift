import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SetupControllerTests {
    @Test func writesAvdOnlyAfterEveryRequiredPackageFinishes() async throws {
        let spec = try SdkSpec.bundled().get()
        let state = SetupTestState(missing: allMissing(spec))
        let installer = FakePackageInstaller(state: state)
        let controller = makeController(spec: spec, state: state, installer: installer)
        controller.agreed = true

        controller.start()
        let result = await finish(controller)

        #expect(result == .finished(.signaled))
        #expect(controller.phase == .succeeded)
        let expected = requiredPackages(spec).flatMap {
            ["start:\($0.installPath)", "done:\($0.installPath)"]
        } + ["avd"]
        #expect(state.events == expected)
    }

    @Test func cancelReturnsToIntroAndRestartKeepsCompletedPackages() async throws {
        let spec = try SdkSpec.bundled().get()
        let state = SetupTestState(missing: allMissing(spec))
        let packages = requiredPackages(spec)
        let installer = FakePackageInstaller(state: state, blockedPath: packages[1].installPath)
        let controller = makeController(spec: spec, state: state, installer: installer)
        controller.agreed = true

        controller.start()
        let reachedSecond = await awaitWithWatchdog(.seconds(3)) {
            await installer.waitForCallCount(2)
        }
        #expect(reachedSecond == .finished(.signaled))
        controller.cancel()
        #expect(controller.phase == .intro)
        let cancellation = try #require(controller.operationTask)
        let cancelled = await awaitWithWatchdog(.seconds(3)) {
            await cancellation.value
            return .signaled
        }
        #expect(cancelled == .finished(.signaled))
        #expect(controller.progressItems.first(where: { $0.key == "package:\(packages[0].installPath)" })?.state == .completed)

        await installer.setBlockedPath(nil)
        controller.start()
        let restarted = await finish(controller)

        #expect(restarted == .finished(.signaled))
        #expect(await installer.calledPaths == [
            packages[0].installPath, packages[1].installPath,
            packages[1].installPath, packages[2].installPath,
        ])
        #expect(controller.phase == .succeeded)
    }

    @Test func retryAfterFailureOnlyInstallsStillMissingItems() async throws {
        let spec = try SdkSpec.bundled().get()
        let state = SetupTestState(missing: allMissing(spec))
        let packages = requiredPackages(spec)
        let installer = FakePackageInstaller(state: state, failingPaths: [packages[1].installPath])
        let controller = makeController(spec: spec, state: state, installer: installer)
        controller.agreed = true

        controller.start()
        let firstAttempt = await finish(controller)
        #expect(firstAttempt == .finished(.signaled))
        #expect(controller.phase == .failed(item: "Android Platform Tools", reason: "fixture install failure"))
        #expect(!state.events.contains("avd"))

        await installer.setFailingPaths([])
        controller.retry()
        let retried = await finish(controller)

        #expect(retried == .finished(.signaled))
        #expect(controller.phase == .succeeded)
        #expect(await installer.calledPaths == [
            packages[0].installPath, packages[1].installPath,
            packages[1].installPath, packages[2].installPath,
        ])
    }

    @Test func insufficientGateDoesNotCallInstaller() async throws {
        let spec = try SdkSpec.bundled().get()
        let state = SetupTestState(missing: allMissing(spec))
        let installer = FakePackageInstaller(state: state)
        let controller = makeController(spec: spec, state: state, installer: installer,
                                       availableBytes: 1_073_741_824)
        controller.agreed = true

        controller.start()

        #expect(controller.phase == .intro)
        #expect(await installer.calledPaths.isEmpty)
        #expect(state.events.isEmpty)
    }

    @Test func finalSetupCheckMustBeEmptyToSucceed() async throws {
        let spec = try SdkSpec.bundled().get()
        let packages = requiredPackages(spec)
        let state = SetupTestState(missing: allMissing(spec), retainedPaths: [packages[2].installPath])
        let installer = FakePackageInstaller(state: state)
        let controller = makeController(spec: spec, state: state, installer: installer)
        controller.agreed = true

        controller.start()
        let result = await finish(controller)

        #expect(result == .finished(.signaled))
        #expect(controller.phase == .failed(item: "Android android-35 Google Play system image",
                                             reason: "重新檢查後仍缺少此項目"))
    }

    private func makeController(
        spec: SdkSpec,
        state: SetupTestState,
        installer: FakePackageInstaller,
        availableBytes: Int64 = 100_000_000_000
    ) -> SetupController {
        let root = URL(fileURLWithPath: "/tmp/setup-controller-tests", isDirectory: true)
        return SetupController(
            spec: spec,
            missing: state.snapshot,
            sdkRoot: root.appendingPathComponent("sdk", isDirectory: true),
            avdDirectory: root.appendingPathComponent("avd", isDirectory: true),
            downloadsDirectory: root.appendingPathComponent("downloads", isDirectory: true),
            installer: installer,
            availableBytes: { availableBytes },
            writeAVD: { state.completeAVD() },
            evaluateSetup: { state.result })
    }

    private func finish(_ controller: SetupController) async -> WatchdogOutcome<SetupTestSignal> {
        guard let task = controller.operationTask else {
            Issue.record("start 沒有建立安裝工作")
            return .watchdogFired
        }
        return await awaitWithWatchdog(.seconds(5)) {
            await task.value
            return .signaled
        }
    }

    private func allMissing(_ spec: SdkSpec) -> [SetupMissingItem] {
        requiredPackages(spec).map {
            SetupMissingItem(kind: .package(installPath: $0.installPath),
                             name: displayName($0, target: spec.androidTarget), size: $0.size)
        } + [SetupMissingItem(kind: .avd(name: "mirage-game"), name: "mirage-game AVD", size: 0)]
    }

    private func requiredPackages(_ spec: SdkSpec) -> [SdkPackageSpec] {
        let gameImage = spec.avds.first(where: { $0.name == "mirage-game" })?.imageManifest
        return spec.packages.filter { package in
            package.path == "emulator" || package.path == "platform-tools"
                || (gameImage.map { package.manifestKey == $0 } ?? false)
        }
    }

    private func displayName(_ package: SdkPackageSpec, target: String) -> String {
        switch package.path {
        case "emulator": "Android Emulator"
        case "platform-tools": "Android Platform Tools"
        default: "Android \(target) Google Play system image"
        }
    }
}

private actor FakePackageInstaller: PackageInstalling {
    private let state: SetupTestState
    private var paths: [String] = []
    private var failingPaths: Set<String>
    private var blockedPath: String?
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(state: SetupTestState, failingPaths: Set<String> = [], blockedPath: String? = nil) {
        self.state = state
        self.failingPaths = failingPaths
        self.blockedPath = blockedPath
    }

    var calledPaths: [String] { paths }

    func waitForCallCount(_ count: Int) async -> SetupTestSignal {
        if paths.count >= count { return .signaled }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append((count, continuation))
        }
        return .signaled
    }

    func setBlockedPath(_ path: String?) { blockedPath = path }
    func setFailingPaths(_ paths: Set<String>) { failingPaths = paths }

    func install(
        _ package: SdkPackageSpec,
        stage: @escaping @Sendable (PackageInstallStage) async -> Void,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        paths.append(package.installPath)
        state.record("start:\(package.installPath)")
        let ready = waiters.filter { paths.count >= $0.0 }
        waiters.removeAll { paths.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        progress(package.size, package.size)
        if blockedPath == package.installPath { try await Task.sleep(for: .seconds(60)) }
        if failingPaths.contains(package.installPath) { throw FakeInstallError.failure }
        await stage(.verifying)
        await stage(.extracting)
        state.completePackage(package.installPath)
    }
}

private enum SetupTestSignal: Equatable, Sendable {
    case signaled
}

private enum FakeInstallError: Error, LocalizedError {
    case failure
    var errorDescription: String? { "fixture install failure" }
}

private final class SetupTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var missingItems: [SetupMissingItem]
    private let retainedPaths: Set<String>
    private var recordedEvents: [String] = []

    init(missing: [SetupMissingItem], retainedPaths: Set<String> = []) {
        missingItems = missing
        self.retainedPaths = retainedPaths
    }

    var snapshot: [SetupMissingItem] {
        lock.lock(); defer { lock.unlock() }
        return missingItems
    }

    var result: SetupCheckResult {
        lock.lock(); defer { lock.unlock() }
        return SetupCheckResult(missing: missingItems, warnings: [])
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedEvents
    }

    func record(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        recordedEvents.append(event)
    }

    func completePackage(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        if !retainedPaths.contains(path) {
            missingItems.removeAll {
                if case .package(let installPath) = $0.kind { return installPath == path }
                return false
            }
        }
        recordedEvents.append("done:\(path)")
    }

    func completeAVD() {
        lock.lock(); defer { lock.unlock() }
        missingItems.removeAll {
            if case .avd = $0.kind { return true }
            return false
        }
        recordedEvents.append("avd")
    }
}
