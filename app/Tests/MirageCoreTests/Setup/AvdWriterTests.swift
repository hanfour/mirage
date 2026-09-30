import Foundation
import Testing
@testable import MirageCore

@Suite("AvdWriter")
struct AvdWriterTests {
    @Test func renderedFilesMatchPythonGoldens() throws {
        let spec = try SdkSpec.bundled().get()
        let game = try #require(spec.avds.first { $0.name == "mirage-game" })
        let configGolden = try golden("mirage-game.config")
        let pointerGolden = try golden("mirage-game.pointer")
        #expect(try AvdWriter.renderConfig(
            spec: spec, avd: game, sdkRoot: URL(fileURLWithPath: "/tmp/mirage-sdk", isDirectory: true))
            == configGolden)
        #expect(AvdWriter.renderPointerIni(
            spec: spec, avd: game, avdDirectory: URL(fileURLWithPath: "/tmp/mirage-avd", isDirectory: true))
            == pointerGolden)
    }

    @Test func writeCreatesAvdDirectoryAndAtomicallyWritesAllFiles() throws {
        let spec = try SdkSpec.bundled().get()
        let game = try #require(spec.avds.first { $0.name == "mirage-game" })
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("avd-writer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let avdDirectory = temporaryRoot.appendingPathComponent("avd", isDirectory: true)
        let sdkRoot = temporaryRoot.appendingPathComponent("sdk", isDirectory: true)

        try AvdWriter.write(spec: spec, avd: game, sdkRoot: sdkRoot, avdDirectory: avdDirectory)

        let config = avdDirectory.appendingPathComponent("mirage-game.avd/config.ini")
        let pointer = avdDirectory.appendingPathComponent("mirage-game.ini")
        let marker = avdDirectory.appendingPathComponent(
            "mirage-game.avd/\(AvdSettings.managedMarkerFilename)")
        #expect(FileManager.default.fileExists(atPath: config.path))
        #expect(FileManager.default.fileExists(atPath: pointer.path))
        #expect(try String(contentsOf: marker, encoding: .utf8) == AvdSettings.managedMarkerContent)
        #expect(AvdSettings.isManaged(at: config.deletingLastPathComponent()))
        #expect(try String(contentsOf: config, encoding: .utf8) ==
                AvdWriter.renderConfig(spec: spec, avd: game, sdkRoot: sdkRoot))
    }

    @Test func writeAppliesConfigOverrideWithoutChangingOtherValues() throws {
        let spec = try SdkSpec.bundled().get()
        let game = try #require(spec.avds.first { $0.name == "mirage-game" })
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("avd-writer-override-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let avdDirectory = temporaryRoot.appendingPathComponent("avd", isDirectory: true)
        let sdkRoot = temporaryRoot.appendingPathComponent("sdk", isDirectory: true)
        let partitionBytes = SetupSpace.minimumTestDataPartitionBytes
        let overrides = [SetupSpace.dataPartitionSizeKey: String(partitionBytes)]

        try AvdWriter.write(spec: spec, avd: game, sdkRoot: sdkRoot,
                            avdDirectory: avdDirectory, configOverrides: overrides)

        let config = avdDirectory.appendingPathComponent("mirage-game.avd/config.ini")
        let written = try String(contentsOf: config, encoding: .utf8)
        let base = try AvdWriter.renderConfig(spec: spec, avd: game, sdkRoot: sdkRoot)
        let originalPartitionBytes = try #require(spec.configBase[SetupSpace.dataPartitionSizeKey])
        let originalLine = "\(SetupSpace.dataPartitionSizeKey) = \(originalPartitionBytes)"
        let updatedLine = "\(SetupSpace.dataPartitionSizeKey) = \(partitionBytes)"
        #expect(written == base.replacingOccurrences(of: originalLine, with: updatedLine))
    }

    private func golden(_ name: String) throws -> String {
        let fixtureDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/avd", isDirectory: true)
        let url = fixtureDirectory.appendingPathComponent("\(name).ini", isDirectory: false)
        try #require(FileManager.default.fileExists(atPath: url.path))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
