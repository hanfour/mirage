import Darwin
import Foundation
import MirageCore
import Observation

@MainActor
@Observable
final class SettingsController {
    let avdName: String
    let isEditable: Bool
    let options: AvdSettings.Options
    var settings: AvdSettings.Values
    var applyMessage: String?
    var applyError: String?

    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let launcherIsManaged: @MainActor (String) -> Bool
    @ObservationIgnored private let instanceState: @MainActor (String) -> InstanceState?
    @ObservationIgnored private let restart: @MainActor (String) async -> Void
    @ObservationIgnored private let readConfig: @MainActor (URL) throws -> String
    @ObservationIgnored private let writeConfig: @MainActor (URL, String) throws -> Void

    init(
        avdName: String,
        avdDirectory: URL,
        hostProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        hostMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        fileManager: FileManager = .default,
        launcherIsManaged: @escaping @MainActor (String) -> Bool,
        instanceState: @escaping @MainActor (String) -> InstanceState?,
        restart: @escaping @MainActor (String) async -> Void,
        readConfig: @escaping @MainActor (URL) throws -> String = {
            try String(contentsOf: $0, encoding: .utf8)
        },
        writeConfig: (@MainActor (URL, String) throws -> Void)? = nil
    ) throws {
        self.avdName = avdName
        configURL = avdDirectory.appendingPathComponent("config.ini", isDirectory: false)
        options = AvdSettings.options(hostProcessorCount: hostProcessorCount,
                                      hostMemoryBytes: hostMemoryBytes)
        settings = try AvdSettings.parseConfig(readConfig(configURL))
        isEditable = AvdSettings.isManaged(at: avdDirectory, fileManager: fileManager)
        self.launcherIsManaged = launcherIsManaged
        self.instanceState = instanceState
        self.restart = restart
        self.readConfig = readConfig
        self.writeConfig = writeConfig ?? { url, contents in
            try Self.writeConfigAtomically(contents, to: url)
        }
        if !isEditable {
            print("[settings] read-only \(avdDirectory.path)")
        }
    }

    var selectableCores: [Int] {
        includingCurrent(settings.cores, in: options.cores)
    }

    var selectableRAM: [Int] {
        includingCurrent(settings.ramMB, in: options.ramMB)
    }

    var selectableResolutions: [AvdSettings.Resolution] {
        includingCurrent(settings.resolution, in: options.resolutions)
    }

    var currentCoreLabel: String {
        AvdSettings.coreChoiceLabel(settings.cores, options: options.cores)
    }

    var currentRAMLabel: String {
        AvdSettings.ramChoiceLabel(settings.ramMB, options: options.ramMB)
    }

    var currentResolutionLabel: String {
        AvdSettings.resolutionChoiceLabel(settings.resolution, options: options.resolutions)
    }

    var applyButtonTitle: String {
        isManagedAndActive ? "套用並重新啟動" : "套用"
    }

    var isExternal: Bool {
        if case .external? = instanceState(avdName) { return true }
        return false
    }

    private var isManagedAndActive: Bool {
        guard launcherIsManaged(avdName) else { return false }
        switch instanceState(avdName) {
        case .launching?, .booting?, .running?, .restarting?, .stopping?:
            return true
        default:
            return false
        }
    }

    func coreLabel(_ value: Int) -> String {
        AvdSettings.coreChoiceLabel(value, options: options.cores)
    }

    func ramLabel(_ value: Int) -> String {
        AvdSettings.ramChoiceLabel(value, options: options.ramMB)
    }

    func resolutionLabel(_ value: AvdSettings.Resolution) -> String {
        AvdSettings.resolutionChoiceLabel(value, options: options.resolutions)
    }

    @discardableResult
    func apply() async -> Bool {
        guard isEditable else { return false }
        applyMessage = nil
        applyError = nil

        do {
            let original = try readConfig(configURL)
            let updated = AvdSettings.updatedConfig(original: original, settings: settings)
            try writeConfig(configURL, updated)
        } catch {
            applyError = error.localizedDescription
            return false
        }

        let restartMode: String
        if isExternal {
            restartMode = "external"
            applyMessage = "下次啟動模擬器時生效"
        } else if isManagedAndActive {
            await restart(avdName)
            restartMode = "yes"
        } else {
            restartMode = "no"
        }
        print("[settings] applied cores=\(settings.cores) ramMB=\(settings.ramMB) "
              + "resolution=\(settings.resolution.description) restart=\(restartMode)")
        return true
    }

    private func includingCurrent<Value: Equatable>(_ current: Value, in options: [Value]) -> [Value] {
        options.contains(current) ? options : [current] + options
    }

    private static func writeConfigAtomically(_ contents: String, to configURL: URL) throws {
        let temporaryURL = configURL.deletingLastPathComponent()
            .appendingPathComponent(".\(configURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Data(contents.utf8).write(to: temporaryURL)

        let result = temporaryURL.path.withCString { source in
            configURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
