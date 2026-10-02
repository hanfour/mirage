import Foundation
import MirageCore

extension AppModel {
    func showSettingsWindow() {
        let presentation = instanceManagerPresentation
        guard !presentation.setupVisible else { return }
        if let settingsWindowController {
            settingsWindowController.show()
            return
        }
        var avdController: SettingsController?
        var avdError: String?
        if let entry = InstanceTable.primaryEntry(in: presentation.entries),
           let launcher = presentation.launcher {
            do {
                avdController = try makeSettingsController(
                    entry: entry,
                    environment: ProcessInfo.processInfo.environment,
                    launcher: launcher)
            } catch {
                avdError = "讀取 AVD 設定失敗：\(error.localizedDescription)"
            }
        }
        let locationError = locationSettings.consumeLoadError()
        let windowController = SettingsWindowController(
            avdController: avdController,
            locationController: locationSettings,
            avdError: avdError,
            initialLocationError: locationError) { [weak self] in
                self?.settingsWindowController = nil
            }
        settingsWindowController = windowController
        windowController.show()
    }

    func applySettingsAutoApplyIfNeeded(entry: InstanceEntry, environment: [String: String]) async {
        let presentation = instanceManagerPresentation
        guard !presentation.settingsAutoApplyAttempted else { return }
        presentation.settingsAutoApplyAttempted = true
        guard let override = environment["MIRAGE_SETTINGS_AUTOAPPLY"] else { return }

        let parsed = AvdSettings.parseAutoApply(
            override,
            hostProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            hostMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        switch parsed {
        case .failure(let error):
            print("[settings] 環境變數覆寫無效：\(error.localizedDescription)")
        case .success(let values):
            guard let launcher = presentation.launcher else { return }
            do {
                let controller = try makeSettingsController(
                    entry: entry, environment: environment, launcher: launcher)
                controller.settings = values
                await controller.apply()
            } catch {
                print("[settings] 環境變數覆寫無法套用：\(error.localizedDescription)")
            }
        }
    }

    private func makeSettingsController(
        entry: InstanceEntry,
        environment: [String: String],
        launcher: EmulatorLauncher
    ) throws -> SettingsController {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let avdHome = MiragePaths.avdDirectory(environment: environment, homeDirectory: home)
        let avdDirectory = avdHome.appendingPathComponent("\(entry.avdName).avd", isDirectory: true)
        return try SettingsController(
            avdName: entry.avdName,
            avdDirectory: avdDirectory,
            launcherIsManaged: { launcher.isManaged($0) },
            instanceState: { launcher.state(for: $0) },
            restart: { await launcher.restart($0) })
    }
}
