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

    @Test func writeCreatesAvdDirectoryAndAtomicallyWritesBothFiles() throws {
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
        #expect(FileManager.default.fileExists(atPath: config.path))
        #expect(FileManager.default.fileExists(atPath: pointer.path))
        #expect(try String(contentsOf: config, encoding: .utf8) ==
                AvdWriter.renderConfig(spec: spec, avd: game, sdkRoot: sdkRoot))
    }

    private func golden(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "ini", subdirectory: "Fixtures/avd"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
