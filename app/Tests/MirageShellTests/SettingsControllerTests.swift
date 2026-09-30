import Foundation
import MirageCore
import Testing
@testable import MirageShell

@MainActor
@Suite("SettingsController")
struct SettingsControllerTests {
    @Test func managedRunningApplyWritesAndRestarts() async throws {
        let directory = try makeAvdDirectory(marked: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        var restarted: [String] = []
        let controller = try makeController(
            directory: directory,
            isManaged: { _ in true },
            state: { _ in .running },
            restart: { restarted.append($0) })
        controller.settings.cores = 4

        #expect(await controller.apply())

        #expect(restarted == ["mirage-game"])
        #expect(try AvdSettings.parseConfig(String(contentsOf: directory.appendingPathComponent("config.ini"), encoding: .utf8)).cores == 4)
    }

    @Test func externalApplyWritesWithoutRestartAndShowsNextLaunchMessage() async throws {
        let directory = try makeAvdDirectory(marked: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        var restarted: [String] = []
        let controller = try makeController(
            directory: directory,
            isManaged: { _ in false },
            state: { _ in .external },
            restart: { restarted.append($0) })

        #expect(await controller.apply())

        #expect(restarted.isEmpty)
        #expect(controller.applyMessage == "下次啟動模擬器時生效")
    }

    @Test func readOnlyApplyDoesNotWriteOrRestart() async throws {
        let directory = try makeAvdDirectory(marked: false)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        var writeCount = 0
        var restartCount = 0
        let controller = try makeController(
            directory: directory,
            isManaged: { _ in true },
            state: { _ in .running },
            restart: { _ in restartCount += 1 },
            writeConfig: { _, _ in writeCount += 1 })

        let applied = await controller.apply()

        #expect(!applied)

        #expect(writeCount == 0)
        #expect(restartCount == 0)
    }

    private func makeController(
        directory: URL,
        isManaged: @escaping @MainActor (String) -> Bool,
        state: @escaping @MainActor (String) -> InstanceState?,
        restart: @escaping @MainActor (String) async -> Void,
        writeConfig: (@MainActor (URL, String) throws -> Void)? = nil
    ) throws -> SettingsController {
        try SettingsController(
            avdName: "mirage-game",
            avdDirectory: directory,
            hostProcessorCount: 8,
            hostMemoryBytes: 16 * 1_073_741_824,
            launcherIsManaged: isManaged,
            instanceState: state,
            restart: restart,
            writeConfig: writeConfig)
    }

    private func makeAvdDirectory(marked: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-controller-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("mirage-game.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = "hw.cpu.ncore = 2\nhw.ramSize = 3072\nhw.lcd.width = 720\nhw.lcd.height = 1600\nhw.lcd.density = 280\n"
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.ini"))
        if marked {
            try Data(AvdSettings.managedMarkerContent.utf8).write(
                to: directory.appendingPathComponent(AvdSettings.managedMarkerFilename))
        }
        return directory
    }
}
