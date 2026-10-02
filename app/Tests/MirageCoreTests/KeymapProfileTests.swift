import Foundation
import Testing
@testable import MirageCore

@Suite struct KeymapProfileTests {
    private let scratch = ScratchDirectories()
    private func sampleProfile() -> KeymapProfile {
        KeymapProfile(gameId: "com.example.game", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.15),
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.8)),
            .look(activation: nil, sensitivity: 1.5),
        ])
    }

    @Test func jsonRoundTrip() throws {
        let profile = sampleProfile()
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(KeymapProfile.self, from: data)
        #expect(decoded == profile)
    }

    @Test func bundledAndUserProfilesWithoutGamepadSurviveStoreRoundTrip() throws {
        let testDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let appDirectory = testDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let bundledDirectory = appDirectory
            .appendingPathComponent("Sources/MirageCore/Resources/profiles", isDirectory: true)
        let bundledFiles = try FileManager.default.contentsOfDirectory(
            at: bundledDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!bundledFiles.isEmpty)

        let userFixture = testDirectory.appendingPathComponent("Fixtures/profiles/user-profile.json")
        let sources = bundledFiles + [userFixture]
        let storeDirectory = scratch.make("mirage-profile-compat")
        let store = ProfileStore(directory: storeDirectory)

        for source in sources {
            let data = try Data(contentsOf: source)
            let profile = try JSONDecoder().decode(KeymapProfile.self, from: data)
            try store.save(profile)
            let loaded = try store.load(gameId: profile.gameId)
            #expect(loaded == profile)
        }
    }

    @Test func validProfilePassesValidation() throws {
        #expect(throws: Never.self) { try sampleProfile().validated() }
    }

    @Test func rejectsOutOfRangeCoordinate() {
        let bad = KeymapProfile(gameId: "g", version: 1, bindings: [
            .tap(key: .key("j"), at: NormPoint(x: 1.5, y: 0.5)),
        ])
        #expect(throws: ProfileError.invalidCoordinate) { try bad.validated() }
    }

    @Test func rejectsNonPositiveRadius() {
        let bad = KeymapProfile(gameId: "g", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0),
        ])
        #expect(throws: ProfileError.invalidRadius) { try bad.validated() }
    }

    @Test func rejectsNonPositiveSensitivity() {
        let bad = KeymapProfile(gameId: "g", version: 1, bindings: [
            .look(activation: nil, sensitivity: 0),
        ])
        #expect(throws: ProfileError.invalidSensitivity) { try bad.validated() }
    }

    @Test func rejectsDuplicateJoystickBinding() {
        let bad = KeymapProfile(gameId: "g", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.15),
            .joystick(up: .key("i"), down: .key("k"), left: .key("j"), right: .key("l"),
                      center: NormPoint(x: 0.8, y: 0.75), radius: 0.15),
        ])
        #expect(throws: ProfileError.identifierConflict) { try bad.validated() }
    }

    @Test func rejectsDuplicateLookBinding() {
        let bad = KeymapProfile(gameId: "g", version: 1, bindings: [
            .look(activation: nil, sensitivity: 1.5),
            .look(activation: .key("r"), sensitivity: 2.0),
        ])
        #expect(throws: ProfileError.identifierConflict) { try bad.validated() }
    }

    @Test func allowsRepeatedTapBindings() throws {
        let profile = KeymapProfile(gameId: "g", version: 1, bindings: [
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.8)),
            .tap(key: .key("k"), at: NormPoint(x: 0.72, y: 0.88)),
            .tap(key: .key("l"), at: NormPoint(x: 0.6, y: 0.9)),
        ])
        #expect(throws: Never.self) { try profile.validated() }
    }
}
