import Foundation
import Testing
@testable import MirageCore

@Suite("OwnedInstances")
struct OwnedInstancesTests {
    private let startedAt = Date(timeIntervalSince1970: 1_790_676_000)

    @Test func reconcileRequiresBothPidAndAvdName() {
        let records = [
            record(avd: "mirage-game", pid: 100),
            record(avd: "mirage-game", pid: 200),
            record(avd: "mirage-poc", pid: 300),
        ]
        let running = [
            instance(avd: "mirage-poc", pid: 100),
            instance(avd: "mirage-game", pid: 300),
        ]

        #expect(OwnedInstances.reconcile(records: records, running: running) == [])
    }

    @Test func reconcileDropsDeadPidAndKeepsLiveMatch() {
        let live = record(avd: "mirage-game", pid: 100)
        let dead = record(avd: "mirage-poc", pid: 200)
        let running = [instance(avd: "mirage-game", pid: 100)]

        #expect(OwnedInstances.reconcile(records: [live, dead], running: running) == [live])
    }

    @Test func missingFileReadsAsEmptyWithoutError() {
        let file = temporaryDirectory().appendingPathComponent("owned-instances.json")
        let result = OwnedInstances.read(from: file)
        #expect(result.records.isEmpty)
        #expect(result.error == nil)
    }

    @Test func corruptedFileReadsAsEmptyAndReportsReason() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("owned-instances.json")
        try Data("{ broken".utf8).write(to: file)

        let result = OwnedInstances.read(from: file)
        #expect(result.records.isEmpty)
        let error = try #require(result.error)
        let reason: String
        if case .corrupted(let message) = error {
            reason = message
        } else {
            reason = ""
        }
        #expect(!reason.isEmpty)
    }

    @Test func writesIso8601JsonAndReadsItBack() throws {
        let directory = temporaryDirectory()
        let file = directory.appendingPathComponent("owned-instances.json")
        let sample = record(avd: "mirage-game", pid: 51234)

        try OwnedInstances.write([sample], to: file)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
        let rows = try #require(json)
        let row = try #require(rows.first)
        #expect(row["avd"] as? String == "mirage-game")
        #expect(row["consolePort"] as? Int == 5554)
        #expect(row["pid"] as? Int == 51234)
        #expect(row["startedAt"] as? String == "2026-09-29T10:00:00Z")
        #expect(OwnedInstances.read(from: file).records == [sample])

        try OwnedInstances.write([], to: file)
        #expect(OwnedInstances.read(from: file).records.isEmpty)
    }

    @Test func addingAndRemovingReturnNewArrays() {
        let existing = record(avd: "mirage-game", pid: 100)
        let added = record(avd: "mirage-poc", pid: 200)
        let original = [existing, existing]

        let afterAdd = OwnedInstances.adding(added, to: original)
        #expect(original == [existing, existing])
        #expect(afterAdd == [existing, existing, added])

        let afterRemove = OwnedInstances.removing(existing, from: original)
        #expect(original == [existing, existing])
        #expect(afterRemove == [existing])
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirage-owned-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func record(avd: String, pid: Int32) -> OwnedRecord {
        OwnedRecord(avd: avd, consolePort: 5554, pid: pid, startedAt: startedAt)
    }

    private func instance(avd: String, pid: Int32) -> EmulatorInstance {
        EmulatorInstance(avdName: avd, consolePort: 5554, grpcPort: 8554, pid: pid)
    }
}
