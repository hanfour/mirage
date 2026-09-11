import Foundation
import Testing

@Suite struct TextEvidenceDirectoryTests {
    @Test func existingFailureEvidenceCannotBeOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let failure = dir.appendingPathComponent("run-failure.json")
        try Data("original-failure".utf8).write(to: failure)
        #expect(throws: (any Error).self) { try TextEvidenceDirectory.requireFresh(dir) }
        #expect(try Data(contentsOf: failure) == Data("original-failure".utf8))
    }
    @Test func freshRunnerLogDoesNotCountAsOldCases() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("swift-live.log"))
        try TextEvidenceDirectory.requireFresh(dir)
    }
}
