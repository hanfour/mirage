import Foundation
import MirageCore
import Testing
@testable import MirageShell

@MainActor
@Suite struct EmulatorLauncherTests {
    @Test func discoveredOwnershipUsesExplorerPidInsteadOfSpawnPid() async throws {
        let ownedFile = temporaryOwnedFile()
        defer { try? FileManager.default.removeItem(at: ownedFile.deletingLastPathComponent()) }
        let harness = LauncherHarness()
        let launcher = harness.makeLauncher(ownedFile: ownedFile)

        await launcher.ensureRunning(harness.game)
        harness.discovered = [.init(avdName: "mirage-game", consolePort: 5554,
                                    grpcPort: 8554, pid: 12345)]
        harness.alive.insert(12345)
        await launcher.tick()

        let records = OwnedInstances.read(from: ownedFile).records
        #expect(records.count == 1)
        let record = try #require(records.first)
        let spawnPid = try #require(harness.spawnPids.first)
        #expect(record.pid == 12345)
        #expect(record.pid != spawnPid)
        #expect(launcher.state(for: "mirage-game") == .booting(since: harness.nowValue))
    }

    @Test func overlappingTickReturnsWhileBootProbeIsSuspended() async throws {
        let ownedFile = temporaryOwnedFile()
        defer { try? FileManager.default.removeItem(at: ownedFile.deletingLastPathComponent()) }
        let harness = LauncherHarness()
        let gate = BootProbeGate()
        harness.bootProbe = { _ in await gate.probe() }
        let launcher = harness.makeLauncher(ownedFile: ownedFile)

        await launcher.ensureRunning(harness.game)
        harness.discovered = [.init(avdName: "mirage-game", consolePort: 5554,
                                    grpcPort: 8554, pid: 12345)]
        harness.alive.insert(12345)
        let firstTick = Task { @MainActor in await launcher.tick() }
        await gate.waitUntilEntered()

        harness.discovered = []
        harness.alive.remove(12345)
        await launcher.tick()
        #expect(harness.spawnCount == 1)

        gate.resume(false)
        await firstTick.value
        await launcher.tick()
        #expect(launcher.state(for: "mirage-game") == .launching(since: harness.nowValue))
        #expect(harness.spawnCount == 2)

        await launcher.tick()
        #expect(harness.spawnCount == 2)
    }

    @Test func managedExitRestartsOnceButSecondExitWithinFiftyNineSecondsFails() async throws {
        let ownedFile = temporaryOwnedFile()
        defer { try? FileManager.default.removeItem(at: ownedFile.deletingLastPathComponent()) }
        let harness = LauncherHarness()
        let launcher = harness.makeLauncher(ownedFile: ownedFile)

        await launcher.ensureRunning(harness.game)
        harness.discovered = [.init(avdName: "mirage-game", consolePort: 5554,
                                    grpcPort: 8554, pid: 12345)]
        harness.alive.insert(12345)
        harness.bootResult = true
        await launcher.tick()
        #expect(launcher.state(for: "mirage-game") == .running)
        #expect(harness.spawnCount == 1)

        harness.discovered = []
        harness.alive.remove(12345)
        harness.spawnRunning[0] = false
        await launcher.tick()
        #expect(harness.spawnCount == 2)

        harness.nowValue = harness.nowValue.addingTimeInterval(59)
        try #require(harness.spawnRunning.indices.contains(1))
        harness.spawnRunning[1] = false
        await launcher.tick()

        #expect(launcher.state(for: "mirage-game") == .failed(.abnormalExit))
        #expect(harness.spawnCount == 2)
    }

    @Test func externalInstanceExitDoesNotSpawnReplacement() async throws {
        let ownedFile = temporaryOwnedFile()
        defer { try? FileManager.default.removeItem(at: ownedFile.deletingLastPathComponent()) }
        let harness = LauncherHarness()
        harness.discovered = [.init(avdName: "mirage-game", consolePort: 5554,
                                    grpcPort: 8554, pid: 12345)]
        harness.alive.insert(12345)
        let launcher = harness.makeLauncher(ownedFile: ownedFile)

        await launcher.ensureRunning(harness.game)
        harness.discovered = []
        harness.alive.remove(12345)
        await launcher.tick()

        #expect(launcher.state(for: "mirage-game") == .external)
        #expect(harness.spawnCount == 0)
    }

    @Test func restartStopsLiveTimedOutProcessBeforeSpawningAgain() async throws {
        let ownedFile = temporaryOwnedFile()
        defer { try? FileManager.default.removeItem(at: ownedFile.deletingLastPathComponent()) }
        let harness = LauncherHarness()
        let launcher = harness.makeLauncher(ownedFile: ownedFile)

        await launcher.ensureRunning(harness.game)
        harness.discovered = [.init(avdName: "mirage-game", consolePort: 5554,
                                    grpcPort: 8554, pid: 12345)]
        harness.alive.insert(12345)
        harness.bootResult = false
        await launcher.tick()
        harness.nowValue = harness.nowValue.addingTimeInterval(120)
        await launcher.tick()
        #expect(launcher.state(for: "mirage-game") == .failed(.bootTimedOut))

        await launcher.restart("mirage-game")

        #expect(harness.spawnCount == 2)
        let stopIndex = try #require(harness.events.firstIndex(of: "signal-12345"))
        let spawnIndex = try #require(harness.events.lastIndex(of: "spawn-2"))
        #expect(stopIndex < spawnIndex)
    }

    @Test func terminationKillsOnlyReconciledOwnedInstances() throws {
        let ownedFile = temporaryOwnedFile()
        defer { try? FileManager.default.removeItem(at: ownedFile.deletingLastPathComponent()) }
        let harness = LauncherHarness()
        harness.discovered = [
            .init(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554, pid: 12345),
            .init(avdName: "mirage-poc", consolePort: 5556, grpcPort: 8556, pid: 23456),
        ]
        harness.alive = [12345, 23456]
        try OwnedInstances.write([
            .init(avd: "mirage-game", consolePort: 5554, pid: 12345, startedAt: harness.nowValue),
        ], to: ownedFile)
        let launcher = harness.makeLauncher(ownedFile: ownedFile, entries: [harness.game, harness.poc])
        launcher.adoptOnLaunch()

        launcher.stopAllOwnedForTermination()

        #expect(harness.syncKillSerials == ["emulator-5554"])
        #expect(harness.alive == [23456])
        #expect(OwnedInstances.read(from: ownedFile).records.isEmpty)
    }

    @Test func terminationSignalsAndWaitsForSpawnWithoutDiscoveryRecord() async throws {
        let ownedFile = temporaryOwnedFile()
        defer { try? FileManager.default.removeItem(at: ownedFile.deletingLastPathComponent()) }
        let harness = LauncherHarness()
        harness.keepSpawnRunningAfterTerminate = true
        let launcher = harness.makeLauncher(ownedFile: ownedFile)

        await launcher.ensureRunning(harness.game)
        let spawnPid = try #require(harness.spawnPids.first)
        #expect(launcher.state(for: "mirage-game") == .launching(since: harness.nowValue))
        #expect(OwnedInstances.read(from: ownedFile).records.isEmpty)

        launcher.stopAllOwnedForTermination()

        #expect(harness.events.contains("signal-\(spawnPid)"))
        #expect(harness.terminationSleepCount == 1)
        #expect(!harness.spawnRunning[0])
    }

    @Test func adoptKeepsMatchingPidAndAvdAndDropsMismatches() throws {
        let ownedFile = temporaryOwnedFile()
        defer { try? FileManager.default.removeItem(at: ownedFile.deletingLastPathComponent()) }
        let harness = LauncherHarness()
        harness.discovered = [
            .init(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554, pid: 12345),
            .init(avdName: "mirage-poc", consolePort: 5556, grpcPort: 8556, pid: 23456),
        ]
        harness.alive = [12345, 23456]
        try OwnedInstances.write([
            .init(avd: "mirage-game", consolePort: 5554, pid: 12345, startedAt: harness.nowValue),
            .init(avd: "mirage-game", consolePort: 5554, pid: 34567, startedAt: harness.nowValue),
            .init(avd: "stale-name", consolePort: 5556, pid: 23456, startedAt: harness.nowValue),
        ], to: ownedFile)
        let launcher = harness.makeLauncher(ownedFile: ownedFile, entries: [harness.game, harness.poc])

        launcher.adoptOnLaunch()

        #expect(launcher.isManaged("mirage-game"))
        #expect(launcher.state(for: "mirage-game") == .booting(since: harness.nowValue))
        #expect(OwnedInstances.read(from: ownedFile).records == [
            .init(avd: "mirage-game", consolePort: 5554, pid: 12345, startedAt: harness.nowValue),
        ])
        #expect(!launcher.isManaged("mirage-poc"))
    }

    @Test func launchCheckFailureDoesNotSpawnAndSetsMatchingFailure() async throws {
        let ownedFile = temporaryOwnedFile()
        defer { try? FileManager.default.removeItem(at: ownedFile.deletingLastPathComponent()) }
        let harness = LauncherHarness()
        harness.filesExist = false
        let launcher = harness.makeLauncher(ownedFile: ownedFile)

        await launcher.ensureRunning(harness.game)

        let expected = URL(fileURLWithPath: "/android-sdk/emulator/emulator")
        #expect(launcher.state(for: "mirage-game") == .failed(.emulatorNotFound(expected)))
        #expect(harness.spawnCount == 0)
    }

    @Test func missingAvdAndAvdInUseFailuresAlsoPreventSpawn() async throws {
        let missingFile = temporaryOwnedFile()
        defer { try? FileManager.default.removeItem(at: missingFile.deletingLastPathComponent()) }
        let missingHarness = LauncherHarness()
        missingHarness.fileExistsCheck = { $0.lastPathComponent != "mirage-game.ini" }
        let missingLauncher = missingHarness.makeLauncher(ownedFile: missingFile)
        await missingLauncher.ensureRunning(missingHarness.game)
        #expect(missingLauncher.state(for: "mirage-game") == .failed(.avdNotFound(
            URL(fileURLWithPath: "/user/Library/Application Support/Mirage/avd/mirage-game.ini"))))
        #expect(missingHarness.spawnCount == 0)

        let conflictFile = temporaryOwnedFile()
        defer { try? FileManager.default.removeItem(at: conflictFile.deletingLastPathComponent()) }
        let conflictHarness = LauncherHarness()
        conflictHarness.discovered = [.init(avdName: "mirage-game", consolePort: 5560,
                                            grpcPort: 8560, pid: 12345)]
        conflictHarness.alive.insert(12345)
        let conflictLauncher = conflictHarness.makeLauncher(ownedFile: conflictFile)
        await conflictLauncher.ensureRunning(conflictHarness.game)
        #expect(conflictLauncher.state(for: "mirage-game") == .failed(.avdInUse(consolePort: 5560)))
        #expect(conflictHarness.spawnCount == 0)
    }

    @Test func spawnErrorIsReportedAsSpawnFailure() async throws {
        let ownedFile = temporaryOwnedFile()
        defer { try? FileManager.default.removeItem(at: ownedFile.deletingLastPathComponent()) }
        let harness = LauncherHarness()
        let launcher = harness.makeLauncher(ownedFile: ownedFile, spawnError: "permission denied")

        await launcher.ensureRunning(harness.game)

        #expect(launcher.state(for: "mirage-game") == .failed(.spawnFailed("permission denied")))
        #expect(harness.spawnCount == 0)
    }

    private func temporaryOwnedFile() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-test-\(UUID().uuidString)", isDirectory: true)
        return directory.appendingPathComponent("owned.json", isDirectory: false)
    }
}

@MainActor
private final class LauncherHarness {
    let game = InstanceEntry(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554)
    let poc = InstanceEntry(avdName: "mirage-poc", consolePort: 5556, grpcPort: 8556)
    var discovered: [EmulatorInstance] = []
    var alive: Set<Int32> = []
    var spawnCount = 0
    var spawnRunning: [Bool] = []
    var spawnPids: [Int32] = []
    var events: [String] = []
    var syncKillSerials: [String] = []
    var filesExist = true
    var bootResult: Bool?
    var bootProbe: (@MainActor (EmulatorEndpoint) async -> Bool?)?
    var stopResult: Bool?
    var fileExistsCheck: ((URL) -> Bool)?
    var nowValue = Date(timeIntervalSince1970: 1_000)
    var spawnError: String?
    var keepSpawnRunningAfterTerminate = false
    var terminationSleepCount = 0

    func makeLauncher(ownedFile: URL, entries: [InstanceEntry]? = nil,
                      spawnError: String? = nil) -> EmulatorLauncher {
        self.spawnError = spawnError
        return EmulatorLauncher(
            entries: entries ?? [game],
            spawn: { [self] _ in
                if let spawnError = self.spawnError {
                    throw NSError(domain: "LauncherTest", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: spawnError])
                }
                spawnCount += 1
                let index = spawnRunning.count
                let pid = Int32(90_000 + index)
                events.append("spawn-\(spawnCount)")
                spawnPids.append(pid)
                spawnRunning.append(true)
                return SpawnedProcess(pid: pid, isRunning: { self.spawnRunning[index] })
            },
            discover: { self.discovered },
            isAlive: { self.alive.contains($0) },
            isBooted: { endpoint in
                if let bootProbe = self.bootProbe { return await bootProbe(endpoint) }
                return self.bootResult
            },
            stopEmulator: { serial in
                self.events.append("adb-\(serial)")
                return self.stopResult
            },
            configureGuest: { serial, key, value in
                self.events.append("setting-\(serial)-\(key)-\(value)")
                return true
            },
            terminatePid: { pid in
                self.events.append("signal-\(pid)")
                self.alive.remove(pid)
                if !self.keepSpawnRunningAfterTerminate,
                   let index = self.spawnPids.firstIndex(of: pid) {
                    self.spawnRunning[index] = false
                }
            },
            syncEmuKill: { serial in
                self.syncKillSerials.append(serial)
                if let port = Int(serial.dropFirst("emulator-".count)),
                   let instance = self.discovered.first(where: { $0.consolePort == port }) {
                    self.alive.remove(instance.pid)
                }
            },
            now: { self.nowValue },
            ownedFile: ownedFile,
            environment: ["ANDROID_SDK_ROOT": "/android-sdk"],
            homeDirectory: URL(fileURLWithPath: "/user", isDirectory: true),
            fileExists: { url in self.fileExistsCheck?(url) ?? self.filesExist },
            createDirectory: { _ in },
            sleep: { _ in },
            terminationSleep: { _ in
                self.terminationSleepCount += 1
                if let index = self.spawnRunning.indices.first {
                    self.spawnRunning[index] = false
                }
            }
        )
    }
}

@MainActor
private final class BootProbeGate {
    private var resultContinuation: CheckedContinuation<Bool?, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var didEnter = false

    func probe() async -> Bool? {
        await withCheckedContinuation { continuation in
            resultContinuation = continuation
            didEnter = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
    }

    func waitUntilEntered() async {
        if !didEnter {
            await withCheckedContinuation { enteredContinuation = $0 }
        }
    }

    func resume(_ result: Bool?) {
        let continuation = resultContinuation
        resultContinuation = nil
        continuation?.resume(returning: result)
    }
}
