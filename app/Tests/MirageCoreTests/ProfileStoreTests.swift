import Foundation
import Testing
@testable import MirageCore

@Suite struct ProfileStoreTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirage-store-test-\(UInt64(bitPattern: Int64(ObjectIdentifier(NSObject()).hashValue)))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func sample() -> KeymapProfile {
        KeymapProfile(gameId: "com.example.game", version: 1, bindings: [
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.8)),
        ])
    }

    @Test func saveThenLoadRoundTrip() throws {
        let store = ProfileStore(directory: tempDir())
        try store.save(sample())
        let loaded = try store.load(gameId: "com.example.game")
        #expect(loaded == sample())
    }

    @Test func loadMissingThrowsNotFound() {
        let store = ProfileStore(directory: tempDir())
        #expect(throws: StoreError.notFound) { try store.load(gameId: "nope") }
    }

    @Test func loadCorruptedThrowsCorrupted() throws {
        let dir = tempDir()
        let store = ProfileStore(directory: dir)
        try "{ not valid json".data(using: .utf8)!
            .write(to: dir.appendingPathComponent("bad.json"))
        #expect(throws: StoreError.corrupted) { try store.load(gameId: "bad") }
    }

    @Test func loadInvalidSchemaThrows() throws {
        let dir = tempDir()
        let store = ProfileStore(directory: dir)
        let bad = KeymapProfile(gameId: "x", version: 1, bindings: [
            .tap(key: .key("j"), at: NormPoint(x: 2.0, y: 0.5)),   // 越界
        ])
        let data = try JSONEncoder().encode(bad)
        try data.write(to: dir.appendingPathComponent("x.json"))
        #expect(throws: ProfileError.invalidCoordinate) { try store.load(gameId: "x") }
    }

    @Test func bundledCanaryProfileLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirage-canary")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = URL(fileURLWithPath: #filePath)          // Tests/.../ProfileStoreTests.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/profiles/com.example.game.json")
        guard FileManager.default.fileExists(atPath: src.path) else { return }  // 路徑差異時略過
        let dst = dir.appendingPathComponent("com.example.game.json")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        let store = ProfileStore(directory: dir)
        #expect(throws: Never.self) { try store.load(gameId: "com.example.game") }
    }
}
