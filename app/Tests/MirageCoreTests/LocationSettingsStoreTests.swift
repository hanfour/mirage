import Foundation
import Testing
@testable import MirageCore

@Suite("LocationSettingsStore")
struct LocationSettingsStoreTests {
    private let scratch = ScratchDirectories()

    @Test func savesAndLoadsTheSameSettings() throws {
        let directory = scratch.make("location-store")
        let store = LocationSettingsStore(fileURL: directory.appendingPathComponent("location.json"))
        let coordinate = try LocationCoordinate(latitude: 25.0339, longitude: 121.5645)
        let preferences = LocationPreferences(
            enabled: true,
            coordinate: coordinate,
            favorites: [SavedLocation(name: "台北 101", coordinate: coordinate)])

        try store.save(preferences)

        #expect(try store.load() == preferences)
    }

    @Test func missingFileUsesDefaultSettings() throws {
        let directory = scratch.make("location-store-empty")
        let store = LocationSettingsStore(fileURL: directory.appendingPathComponent("location.json"))

        #expect(try store.load() == LocationPreferences())
    }

    @Test func corruptedFileReportsAnError() throws {
        let directory = scratch.make("location-store-corrupt")
        let file = directory.appendingPathComponent("location.json")
        try Data("{ damaged".utf8).write(to: file)
        let store = LocationSettingsStore(fileURL: file)
        var didThrow = false

        do {
            _ = try store.load()
        } catch {
            didThrow = true
        }

        #expect(didThrow)
    }
}
