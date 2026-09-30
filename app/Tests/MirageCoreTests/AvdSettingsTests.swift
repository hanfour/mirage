import Foundation
import Testing
@testable import MirageCore

@Suite("AvdSettings")
struct AvdSettingsTests {
    @Test func optionsRespectHostCoreAndHalfMemoryLimits() {
        let options = AvdSettings.options(hostProcessorCount: 4, hostMemoryBytes: 8 * 1_073_741_824)

        #expect(options.cores == [2, 4])
        #expect(options.ramMB == [2048, 3072, 4096])
        #expect(options.resolutions.count == 3)
    }

    @Test func updatedConfigChangesOnlySettingsAndPreservesOtherLines() {
        let original = "# keep exactly\n\navd.name = sample  \nhw.cpu.ncore= 1  \nhw.ramSize = 5000\nhw.lcd.width = 700\nother.key=value\n"
        let settings = AvdSettings.Values(
            cores: 4,
            ramMB: 4096,
            resolution: .init(width: 720, height: 1600, density: 280))

        let updated = AvdSettings.updatedConfig(original: original, settings: settings)

        #expect(updated == "# keep exactly\n\navd.name = sample  \nhw.cpu.ncore= 4  \nhw.ramSize = 4096\nhw.lcd.width = 720\nother.key=value\nhw.lcd.height = 1600\nhw.lcd.density = 280\n")
    }

    @Test func updatedConfigAppendsMissingFieldsAtEnd() {
        let settings = AvdSettings.Values(
            cores: 2,
            ramMB: 3072,
            resolution: .init(width: 1080, height: 2400, density: 420))

        let updated = AvdSettings.updatedConfig(original: "avd.name = sample", settings: settings)

        #expect(updated == "avd.name = sample\nhw.cpu.ncore = 2\nhw.ramSize = 3072\nhw.lcd.width = 1080\nhw.lcd.height = 2400\nhw.lcd.density = 420\n")
    }

    @Test func parserAcceptsConfigIniSpacingAndComments() throws {
        let parsed = try AvdSettings.parseConfig("# heading\n hw.cpu.ncore=2 \n\nhw.ramSize = 3072\nhw.lcd.width=720\nhw.lcd.height = 1600\nhw.lcd.density=280\n")

        #expect(parsed == AvdSettings.Values(
            cores: 2,
            ramMB: 3072,
            resolution: .init(width: 720, height: 1600, density: 280)))
    }

    @Test func customValuesHaveExplicitLabels() {
        let options = AvdSettings.options(hostProcessorCount: 4, hostMemoryBytes: 8 * 1_073_741_824)

        #expect(AvdSettings.coreChoiceLabel(3, options: options.cores) == "自訂：3")
        #expect(AvdSettings.ramChoiceLabel(5000, options: options.ramMB) == "自訂：5000 MB")
        #expect(AvdSettings.resolutionChoiceLabel(
            .init(width: 700, height: 1500, density: 260), options: options.resolutions)
            == "自訂：700x1500@260")
    }

    @Test func unmarkedAvdIsReadOnly() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(!AvdSettings.isManaged(at: directory))
        let marker = directory.appendingPathComponent(AvdSettings.managedMarkerFilename)
        try Data(AvdSettings.managedMarkerContent.utf8).write(to: marker)
        #expect(AvdSettings.isManaged(at: directory))
    }

    @Test func parsesAutoApplyAndRejectsUnknownResolution() throws {
        let valid = AvdSettings.parseAutoApply(
            "cores=2;ramMB=3072;resolution=720x1600",
            hostProcessorCount: 4,
            hostMemoryBytes: 8 * 1_073_741_824)
        #expect(try valid.get() == AvdSettings.Values(
            cores: 2,
            ramMB: 3072,
            resolution: .init(width: 720, height: 1600, density: 280)))

        let invalid = AvdSettings.parseAutoApply(
            "cores=2;ramMB=3072;resolution=720x1500",
            hostProcessorCount: 4,
            hostMemoryBytes: 8 * 1_073_741_824)
        #expect({
            if case .failure = invalid { return true }
            return false
        }())
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("avd-settings-\(UUID().uuidString)", isDirectory: true)
    }
}
