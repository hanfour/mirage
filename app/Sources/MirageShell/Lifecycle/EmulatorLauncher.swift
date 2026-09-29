import Darwin
import Foundation
import MirageCore

@MainActor
struct SpawnedProcess {
    let process: Process?
    let pid: Int32
    private let running: @MainActor () -> Bool

    init(process: Process) {
        self.process = process
        pid = process.processIdentifier
        running = { process.isRunning }
    }

    init(pid: Int32, isRunning: @escaping @MainActor () -> Bool) {
        process = nil
        self.pid = pid
        running = isRunning
    }

    var isRunning: Bool { running() }
}

@MainActor
final class EmulatorLauncher {
    private struct Runtime {
        let entry: InstanceEntry
        var state: InstanceState
        var lastRestartAt: Date?
        var spawned: SpawnedProcess?
        var ownedRecord: OwnedRecord?
    }

    typealias StopEmulator = @MainActor (String) async -> Bool?
    typealias ConfigureGuest = @MainActor (String, String, String) async -> Bool?

    private let entries: [InstanceEntry]
    private let spawn: @MainActor (LaunchPlan) throws -> SpawnedProcess
    private let discover: @MainActor () -> [EmulatorInstance]
    private let isAlive: @MainActor (Int32) -> Bool
    private let isBooted: @MainActor (EmulatorEndpoint) async -> Bool?
    private let stopEmulator: StopEmulator
    private let configureGuest: ConfigureGuest
    private let terminatePid: @MainActor (Int32) -> Void
    private let syncEmuKill: @MainActor (String) -> Void
    private let now: @MainActor () -> Date
    private let ownedFile: URL
    private let environment: [String: String]
    private let homeDirectory: URL
    private let fileExists: @MainActor (URL) -> Bool
    private let createDirectory: @MainActor (URL) throws -> Void
    private let readOwned: @MainActor (URL) -> OwnedInstancesReadResult
    private let writeOwned: @MainActor ([OwnedRecord], URL) throws -> Void
    private let sleep: @MainActor (Duration) async -> Void
    private let terminationSleep: @MainActor (Duration) -> Void
    private let onStateChange: @MainActor (InstanceEntry, InstanceState) -> Void
    private var runtimes: [String: Runtime] = [:]
    private var ownedRecords: [OwnedRecord] = []
    private var isTicking = false

    init(
        entries: [InstanceEntry],
        spawn: @escaping @MainActor (LaunchPlan) throws -> SpawnedProcess,
        discover: @escaping @MainActor () -> [EmulatorInstance],
        isAlive: @escaping @MainActor (Int32) -> Bool,
        isBooted: @escaping @MainActor (EmulatorEndpoint) async -> Bool?,
        stopEmulator: @escaping StopEmulator,
        configureGuest: @escaping ConfigureGuest,
        terminatePid: @escaping @MainActor (Int32) -> Void = { _ = Darwin.kill($0, SIGTERM) },
        syncEmuKill: @escaping @MainActor (String) -> Void,
        now: @escaping @MainActor () -> Date = Date.init,
        ownedFile: URL,
        environment: [String: String],
        homeDirectory: URL,
        fileExists: @escaping @MainActor (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        createDirectory: @escaping @MainActor (URL) throws -> Void = {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        },
        readOwned: @escaping @MainActor (URL) -> OwnedInstancesReadResult = OwnedInstances.read(from:),
        writeOwned: @escaping @MainActor ([OwnedRecord], URL) throws -> Void = OwnedInstances.write(_:to:),
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        terminationSleep: @escaping @MainActor (Duration) -> Void = {
            Thread.sleep(forTimeInterval: Double($0.components.seconds)
                         + Double($0.components.attoseconds) / 1e18)
        },
        onStateChange: @escaping @MainActor (InstanceEntry, InstanceState) -> Void = { _, _ in }
    ) {
        self.entries = entries
        self.spawn = spawn
        self.discover = discover
        self.isAlive = isAlive
        self.isBooted = isBooted
        self.stopEmulator = stopEmulator
        self.configureGuest = configureGuest
        self.terminatePid = terminatePid
        self.syncEmuKill = syncEmuKill
        self.now = now
        self.ownedFile = ownedFile
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.fileExists = fileExists
        self.createDirectory = createDirectory
        self.readOwned = readOwned
        self.writeOwned = writeOwned
        self.sleep = sleep
        self.terminationSleep = terminationSleep
        self.onStateChange = onStateChange
    }

    func state(for avd: String) -> InstanceState? { runtimes[avd]?.state }

    func state(forGrpcPort port: Int) -> InstanceState? {
        guard let runtime = runtimes.values.first(where: { $0.entry.grpcPort == port }) else { return nil }
        return runtime.state
    }

    func entry(forGrpcPort port: Int) -> InstanceEntry? {
        runtimes.values.first(where: { $0.entry.grpcPort == port })?.entry
            ?? entries.first(where: { $0.grpcPort == port })
    }

    func isManaged(_ avd: String) -> Bool {
        guard let state = runtimes[avd]?.state else { return false }
        if case .external = state { return false }
        return true
    }

    func adoptOnLaunch() {
        let discovered = discover()
        let result = readOwned(ownedFile)
        if let error = result.error {
            NSLog("[launcher] owned instances 讀取失敗：%@", error.localizedDescription)
        }
        ownedRecords = OwnedInstances.reconcile(records: result.records, running: discovered)
        persistOwnedRecords()

        for record in ownedRecords {
            guard let instance = discovered.first(where: {
                $0.pid == record.pid && $0.avdName == record.avd
            }) else { continue }
            let entry = tableEntry(for: instance)
            let since = now()
            let state = InstanceState.booting(since: since)
            runtimes[record.avd] = Runtime(entry: entry, state: state,
                                           lastRestartAt: nil, spawned: nil, ownedRecord: record)
            logChange(entry.avdName, old: .stopped, event: "adopted", new: state)
            onStateChange(entry, state)
        }
    }

    func ensureRunning(_ entry: InstanceEntry) async {
        if let runtime = runtimes[entry.avdName] {
            if case .stopped = runtime.state {
                await send(entry.avdName, .launchRequested)
            }
            return
        }

        if discover().contains(where: {
            $0.avdName == entry.avdName && $0.consolePort == entry.consolePort
        }) {
            let old: InstanceState = .stopped
            runtimes[entry.avdName] = Runtime(entry: entry, state: .external, lastRestartAt: nil,
                                              spawned: nil, ownedRecord: nil)
            logChange(entry.avdName, old: old, event: "discovered", new: .external)
            onStateChange(entry, .external)
            return
        }

        runtimes[entry.avdName] = Runtime(entry: entry, state: .stopped, lastRestartAt: nil,
                                          spawned: nil, ownedRecord: nil)
        await send(entry.avdName, .launchRequested)
    }

    func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        let discovered = discover()
        for avd in runtimes.keys.sorted() {
            guard var runtime = runtimes[avd] else { continue }

            if case .launching = runtime.state,
               let instance = discovered.first(where: {
                   $0.avdName == runtime.entry.avdName && $0.consolePort == runtime.entry.consolePort
               }), runtime.ownedRecord == nil {
                let record = OwnedRecord(avd: instance.avdName, consolePort: instance.consolePort,
                                         pid: instance.pid, startedAt: now())
                ownedRecords.removeAll { $0.avd == instance.avdName }
                ownedRecords = OwnedInstances.adding(record, to: ownedRecords)
                runtime.ownedRecord = record
                runtimes[avd] = runtime
                persistOwnedRecords()
                let spawnPid = runtime.spawned.map { String($0.pid) } ?? "none"
                print("[launcher] \(instance.avdName) spawnPid=\(spawnPid) discoveryPid=\(instance.pid)")
                await send(avd, .discoveryFileAppeared)
                guard let updated = runtimes[avd] else { continue }
                runtime = updated
            }

            let exited: Bool
            if let record = runtime.ownedRecord {
                exited = !isAlive(record.pid)
            } else {
                exited = runtime.spawned.map { !$0.isRunning } ?? false
            }
            if exited {
                if let record = runtime.ownedRecord {
                    ownedRecords = OwnedInstances.removing(record, from: ownedRecords)
                    persistOwnedRecords()
                }
                runtime.ownedRecord = nil
                runtime.spawned = nil
                runtimes[avd] = runtime
                await send(avd, .processExited)
                guard let updated = runtimes[avd] else { continue }
                runtime = updated
            }

            if case .booting = runtime.state {
                let endpoint = EmulatorEndpoint(host: "localhost", port: runtime.entry.grpcPort)
                let probeStartedAt = ProcessInfo.processInfo.systemUptime
                NSLog("[launcher] %@ bootProbe start", avd)
                let bootProbeResult = await isBooted(endpoint)
                let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - probeStartedAt) * 1_000
                let resultDescription = bootProbeResult.map { $0 ? "true" : "false" } ?? "nil"
                NSLog("[launcher] %@ bootProbe end result=%@ ms=%.0f",
                      avd, resultDescription, elapsedMilliseconds)
                if let booted = bootProbeResult, booted {
                    if case .booting? = runtimes[avd]?.state {
                        await send(avd, .booted)
                        if case .running? = runtimes[avd]?.state,
                           await configureGuest("emulator-\(runtime.entry.consolePort)",
                                                "show_ime_with_hard_keyboard", "0") != true {
                            NSLog("[launcher] %@ 設定 show_ime_with_hard_keyboard 失敗", avd)
                        }
                    }
                }
            }

            await send(avd, .timeElapsed)
        }
    }

    func restart(_ avd: String) async {
        guard let runtime = runtimes[avd] else { return }
        if case .external = runtime.state { return }

        let alive = (runtime.ownedRecord.map { isAlive($0.pid) } ?? false)
            || (runtime.spawned?.isRunning ?? false)
        if alive {
            await send(avd, .stopRequested)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            while clock.now < deadline {
                if case .stopped? = runtimes[avd]?.state { break }
                await sleep(.milliseconds(100))
                await tick()
            }
            guard case .stopped? = runtimes[avd]?.state else { return }
            await send(avd, .launchRequested)
            return
        }

        switch runtime.state {
        case .failed:
            clearDeadTracking(for: avd)
            await send(avd, .userRestartRequested)
        case .stopped:
            clearDeadTracking(for: avd)
            await send(avd, .launchRequested)
        default:
            return
        }
    }

    func stopAllOwnedForTermination() {
        let unregisteredSpawns = runtimes.values.compactMap { runtime -> SpawnedProcess? in
            guard runtime.ownedRecord == nil,
                  let spawned = runtime.spawned,
                  spawned.isRunning else { return nil }
            return spawned
        }

        for record in ownedRecords {
            syncEmuKill("emulator-\(record.consolePort)")
        }
        for spawned in unregisteredSpawns {
            terminatePid(spawned.pid)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline
            && (ownedRecords.contains(where: { isAlive($0.pid) })
                || unregisteredSpawns.contains(where: { $0.isRunning })) {
            terminationSleep(.milliseconds(100))
        }
        let remaining = ownedRecords.filter { isAlive($0.pid) }
        let exited = ownedRecords.filter { !isAlive($0.pid) }
        for record in exited {
            if var runtime = runtimes[record.avd] {
                runtime.ownedRecord = nil
                runtimes[record.avd] = runtime
            }
        }
        ownedRecords = remaining
        persistOwnedRecords()
    }

    private func send(_ avd: String, _ event: InstanceEvent) async {
        guard var runtime = runtimes[avd] else { return }
        let old = runtime.state
        let transition = old.next(event: event, now: now(), lastRestartAt: runtime.lastRestartAt)
        runtime.state = transition.state
        runtime.lastRestartAt = transition.lastRestartAt
        runtimes[avd] = runtime

        if old != transition.state {
            logChange(avd, old: old, event: String(describing: event), new: transition.state)
            onStateChange(runtime.entry, transition.state)
        }

        switch transition.action {
        case .none, .showFailure:
            return
        case .launchProcess:
            await launch(runtime.entry)
        case .stopProcess:
            await stop(runtime.entry)
        }
    }

    private func launch(_ entry: InstanceEntry) async {
        let sdkRoot = SdkLocator(environment: environment, homeDirectory: homeDirectory).root
        if let failure = LaunchCheck.failure(instance: entry, sdkRoot: sdkRoot,
                                             environment: environment, homeDirectory: homeDirectory,
                                             running: discover(), fileExists: fileExists) {
            await send(entry.avdName, .launchFailed(failure))
            return
        }

        let plan = LaunchPlan(instance: entry, sdkRoot: sdkRoot, homeDirectory: homeDirectory,
                              environment: environment)
        do {
            try createDirectory(plan.logFile.deletingLastPathComponent())
            let process = try spawn(plan)
            if var runtime = runtimes[entry.avdName] {
                runtime.spawned = process
                runtimes[entry.avdName] = runtime
            }
            await send(entry.avdName, .launchStarted)
        } catch {
            await send(entry.avdName, .launchFailed(.spawnFailed(error.localizedDescription)))
        }
    }

    private func stop(_ entry: InstanceEntry) async {
        let serial = "emulator-\(entry.consolePort)"
        if let result = await stopEmulator(serial) {
            if !result { NSLog("[launcher] %@ adb emu kill 失敗", entry.avdName) }
            return
        }
        let runtime = runtimes[entry.avdName]
        let recordedPid = runtime?.ownedRecord?.pid
        let spawnedPid = runtime?.spawned?.pid
        let pid = recordedPid.flatMap { isAlive($0) ? $0 : nil }
            ?? spawnedPid.flatMap { isAlive($0) ? $0 : nil }
            ?? recordedPid ?? spawnedPid
        if let pid { terminatePid(pid) }
    }

    private func clearDeadTracking(for avd: String) {
        guard var runtime = runtimes[avd] else { return }
        if let record = runtime.ownedRecord {
            ownedRecords = OwnedInstances.removing(record, from: ownedRecords)
            persistOwnedRecords()
        }
        runtime.ownedRecord = nil
        runtime.spawned = nil
        runtimes[avd] = runtime
    }

    private func tableEntry(for instance: EmulatorInstance) -> InstanceEntry {
        entries.first(where: {
            $0.avdName == instance.avdName && $0.consolePort == instance.consolePort
        }) ?? InstanceEntry(avdName: instance.avdName, consolePort: instance.consolePort,
                            grpcPort: instance.grpcPort)
    }

    private func persistOwnedRecords() {
        do {
            try writeOwned(ownedRecords, ownedFile)
        } catch {
            NSLog("[launcher] owned instances 寫入失敗：%@", error.localizedDescription)
        }
    }

    private func logChange(_ avd: String, old: InstanceState, event: String, new: InstanceState) {
        print("[launcher] \(avd) \(stateName(old)) --\(event)--> \(stateName(new))")
    }

    private func stateName(_ state: InstanceState) -> String {
        switch state {
        case .stopped: "stopped"
        case .launching: "launching"
        case .booting: "booting"
        case .running: "running"
        case .restarting: "restarting"
        case .stopping: "stopping"
        case .failed(let failure): "failed(\(String(describing: failure)))"
        case .external: "external"
        }
    }

    static func spawnProcess(_ plan: LaunchPlan) throws -> SpawnedProcess {
        try Data().write(to: plan.logFile, options: .atomic)
        let output = try FileHandle(forWritingTo: plan.logFile)
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment.merge(plan.environment) { _, resolved in resolved }
        process.environment = childEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            try? output.close()
            throw error
        }
        try? output.close()
        return SpawnedProcess(process: process)
    }

    static func synchronousEmuKill(adb: URL, serial: String) {
        let process = Process()
        process.executableURL = adb
        process.arguments = ["-s", serial, "emu", "kill"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }

        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while process.isRunning && ContinuousClock().now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
        } else {
            process.waitUntilExit()
        }
    }
}
