import AppKit
import Darwin
import Foundation
import Observation
import MirageCore

typealias SetupPresenter = @MainActor (SetupController, @MainActor () -> Void) -> Void

@MainActor
@Observable
final class InstanceManagerPresentation {
    var launcher: EmulatorLauncher?
    var entries: [InstanceEntry] = []
    var currentInstanceState: InstanceState?
    var tableError: InstanceTableError?
    var specError: SdkSpecError?
    var setupVisible = false
    var currentAVD: String?
    var tickTask: Task<Void, Never>?
    var settingsAutoApplyAttempted = false

    var logURL: URL? {
        guard let currentAVD else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Mirage", isDirectory: true)
            .appendingPathComponent("emulator-\(currentAVD).log", isDirectory: false)
    }
}

extension AppModel {
    // Optional hooks let the missing-setup path return in tests without opening a real window.
    func prepareInstanceLauncher(
        environment suppliedEnvironment: [String: String]? = nil,
        discoverInstances: (() -> [EmulatorInstance])? = nil,
        presentSetup: SetupPresenter? = nil
    ) async {
        let presentation = instanceManagerPresentation
        guard presentation.launcher == nil, presentation.tableError == nil,
              presentation.specError == nil else { return }
        let environment = suppliedEnvironment ?? ProcessInfo.processInfo.environment
        guard environment["MIRAGE_HOST"] == nil, environment["MIRAGE_PORT"] == nil else { return }

        switch InstanceTable.bundled() {
        case .failure(let error):
            instanceManagerPresentation.tableError = error
            NSLog("[launcher] 實例表讀取失敗：%@", error.localizedDescription)
            showLauncherBannerInBackgroundMode()
            return
        case .success(let entries):
            guard let first = InstanceTable.primaryEntry(in: entries) else {
                let error = InstanceTableError(line: 1, reason: "實例表沒有任何實例")
                instanceManagerPresentation.tableError = error
                NSLog("[launcher] 實例表讀取失敗：%@", error.localizedDescription)
                return
            }

            let home = FileManager.default.homeDirectoryForCurrentUser
            presentation.entries = entries
            presentation.tableError = nil
            presentation.specError = nil

            let discoveredInstances = discoverInstances?() ?? EmulatorDiscovery.instances()
            let isExpectedExternalInstance = discoveredInstances.contains {
                $0.avdName == first.avdName && $0.consolePort == first.consolePort
            }
            guard !isExpectedExternalInstance else {
                await startInstanceLauncher(entries: entries, environment: environment, home: home)
                return
            }

            let options = SetupLaunchOptions.parse(environment: environment)
            for warning in options.warnings {
                print("[setup] 環境變數覆寫無效：\(warning)")
            }
            let spec: SdkSpec
            switch options.loadSdkSpec() {
            case .failure(let error):
                presentation.specError = error
                NSLog("[launcher] SDK 設定檔讀取失敗：%@", error.localizedDescription)
                showLauncherBannerInBackgroundMode()
                return
            case .success(let loaded):
                spec = loaded
            }

            let sdkRoot = MiragePaths.sdkRoot(environment: environment, homeDirectory: home)
            let avdDirectory = MiragePaths.avdDirectory(environment: environment, homeDirectory: home)
            let downloadsDirectory = MiragePaths.downloadsDirectory(homeDirectory: home)
            let initialCheck = Self.evaluateSetup(spec: spec, sdkRoot: sdkRoot, avdDirectory: avdDirectory)
            for warning in initialCheck.warnings {
                print("[setup] warning \(warning.message)")
            }
            guard !initialCheck.missing.isEmpty else {
                await startInstanceLauncher(entries: entries, environment: environment, home: home)
                return
            }

            let setupController = SetupController(
                spec: spec,
                missing: initialCheck.missing,
                sdkRoot: sdkRoot,
                avdDirectory: avdDirectory,
                downloadsDirectory: downloadsDirectory,
                installer: PackageInstaller(sdkRoot: sdkRoot, downloadsDirectory: downloadsDirectory),
                availableBytes: {
                    if let fake = options.fakeAvailableBytes { return fake }
                    return Self.availableCapacity(at: downloadsDirectory)
                },
                writeAVD: {
                    guard let game = spec.avds.first(where: { $0.name == "mirage-game" }) else { return }
                    try AvdWriter.write(spec: spec, avd: game, sdkRoot: sdkRoot, avdDirectory: avdDirectory)
                },
                evaluateSetup: {
                    return Self.evaluateSetup(spec: spec, sdkRoot: sdkRoot, avdDirectory: avdDirectory)
                })
            presentation.setupVisible = true
            let setupSucceeded: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                self.instanceManagerPresentation.setupVisible = false
                self.setupWindowController = nil
                if self.launchPreferences.effectiveBackgroundMode {
                    NSApp.setActivationPolicy(.accessory)
                } else {
                    self.windowController.window().makeKeyAndOrderFront(nil)
                }
                Task { @MainActor in
                    await self.startInstanceLauncher(entries: entries, environment: environment, home: home)
                    if self.lifecycle != nil { self.applyBackgroundModeAfterStart() }
                }
            }

            if let presentSetup {
                presentSetup(setupController, setupSucceeded)
            } else {
                if !launchPreferences.effectiveBackgroundMode {
                    windowController.window().orderOut(nil)
                }
                let windowController = SetupWindowController(
                    controller: setupController, onSuccessfulClose: setupSucceeded)
                self.setupWindowController = windowController
                windowController.show()
            }
            if options.autostart {
                setupController.agreed = true
                setupController.start()
            }
        }
    }

    private func startInstanceLauncher(
        entries: [InstanceEntry], environment: [String: String], home: URL
    ) async {
        let presentation = instanceManagerPresentation
        guard let first = InstanceTable.primaryEntry(in: entries) else { return }
        let ownedFile = home.appendingPathComponent(
            "Library/Application Support/Mirage/owned-instances.json", isDirectory: false)
        let launcher = EmulatorLauncher(
            entries: entries,
            spawn: EmulatorLauncher.spawnProcess,
            discover: EmulatorDiscovery.instances,
            isAlive: Self.pidIsAlive,
            isBooted: { await BootProbe.isBooted(endpoint: $0, timeout: .seconds(1)) },
            stopEmulator: { serial in
                guard let adb = AdbClient.standard(serial: serial, environment: environment,
                                                  homeDirectory: home) else { return nil }
                return await adb.emuKill()
            },
            configureGuest: { serial, key, value in
                guard let adb = AdbClient.standard(serial: serial, environment: environment,
                                                  homeDirectory: home) else { return nil }
                return await adb.setSecureSetting(key, value)
            },
            syncEmuKill: { serial in
                EmulatorLauncher.synchronousEmuKill(
                    adb: SdkLocator(environment: environment, homeDirectory: home).adbBinary,
                    serial: serial)
            },
            ownedFile: ownedFile,
            environment: environment,
            homeDirectory: home,
            onStateChange: { [weak self, weak presentation] entry, state in
                guard let self, let presentation else { return }
                if self.currentEndpoint.port == entry.grpcPort {
                    presentation.currentInstanceState = state
                }
                self.updateCurrentInstancePresentation()
                guard let primary = InstanceTable.primaryEntry(in: presentation.entries),
                      entry.avdName == primary.avdName else {
                    return
                }
                switch state {
                case .running, .external:
                    Task { @MainActor [weak self] in
                        await self?.applySettingsAutoApplyIfNeeded(entry: entry, environment: environment)
                    }
                default:
                    break
                }
            }
        )
        presentation.launcher = launcher
        launcher.adoptOnLaunch()
        updateCurrentInstancePresentation()
        await launcher.ensureRunning(first)
        presentation.tickTask?.cancel()
        presentation.tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await launcher.tick()
            }
        }
    }

    private static func evaluateSetup(spec: SdkSpec, sdkRoot: URL, avdDirectory: URL) -> SetupCheckResult {
        let fileManager = FileManager.default
        return SetupCheck.evaluate(
            spec: spec,
            sdkRoot: sdkRoot,
            avdDirectory: avdDirectory,
            fileExists: { fileManager.fileExists(atPath: $0.path) },
            readFile: { try String(contentsOf: $0, encoding: .utf8) })
    }

    private static func availableCapacity(at directory: URL) -> Int64 {
        let fileManager = FileManager.default
        var volume = directory
        while !fileManager.fileExists(atPath: volume.path), volume.path != "/" {
            volume.deleteLastPathComponent()
        }
        let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private func showLauncherBannerInBackgroundMode() {
        guard launchPreferences.effectiveBackgroundMode else { return }
        let window = windowController.window()
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func restartCurrentInstance() async {
        let presentation = instanceManagerPresentation
        guard let avd = presentation.currentAVD, let launcher = presentation.launcher,
              launcher.isManaged(avd) else { return }
        await launcher.restart(avd)
    }

    func updateCurrentInstancePresentation() {
        let presentation = instanceManagerPresentation
        let launcher = presentation.launcher
        let port = currentEndpoint.port
        presentation.currentInstanceState = launcher?.state(forGrpcPort: port)
        let entry = launcher?.entry(forGrpcPort: port)
            ?? presentation.entries.first(where: { $0.grpcPort == port })
        let discovered = EmulatorDiscovery.instances().first(where: { $0.grpcPort == port })
        presentation.currentAVD = entry?.avdName ?? discovered?.avdName
    }

    private static func pidIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let result = Darwin.kill(pid, 0)
        return result == 0 || errno == EPERM
    }
}
