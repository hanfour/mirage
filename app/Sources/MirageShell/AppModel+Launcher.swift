import AppKit
import Darwin
import Foundation
import Observation
import MirageCore

@MainActor
@Observable
final class InstanceManagerPresentation {
    var launcher: EmulatorLauncher?
    var entries: [InstanceEntry] = []
    var currentInstanceState: InstanceState?
    var tableError: InstanceTableError?
    var currentAVD: String?
    var tickTask: Task<Void, Never>?

    var logURL: URL? {
        guard let currentAVD else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Mirage", isDirectory: true)
            .appendingPathComponent("emulator-\(currentAVD).log", isDirectory: false)
    }
}

@MainActor
private enum InstanceManagerPresentationStore {
    private static let values = NSMapTable<AppModel, InstanceManagerPresentation>.weakToStrongObjects()

    static func value(for model: AppModel) -> InstanceManagerPresentation {
        if let value = values.object(forKey: model) { return value }
        let value = InstanceManagerPresentation()
        values.setObject(value, forKey: model)
        return value
    }
}

extension AppModel {
    var instanceManagerPresentation: InstanceManagerPresentation {
        InstanceManagerPresentationStore.value(for: self)
    }

    func prepareInstanceLauncher() async {
        let presentation = instanceManagerPresentation
        guard presentation.launcher == nil, presentation.tableError == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        guard environment["MIRAGE_HOST"] == nil, environment["MIRAGE_PORT"] == nil else { return }

        switch InstanceTable.bundled() {
        case .failure(let error):
            instanceManagerPresentation.tableError = error
            NSLog("[launcher] 實例表讀取失敗：%@", error.localizedDescription)
            return
        case .success(let entries):
            guard let first = entries.first else {
                let error = InstanceTableError(line: 1, reason: "實例表沒有任何實例")
                instanceManagerPresentation.tableError = error
                NSLog("[launcher] 實例表讀取失敗：%@", error.localizedDescription)
                return
            }

            let home = FileManager.default.homeDirectoryForCurrentUser
            let ownedFile = home.appendingPathComponent(
                "Library/Application Support/Mirage/owned-instances.json", isDirectory: false)
            presentation.entries = entries
            presentation.tableError = nil

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
