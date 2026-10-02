import Foundation
import MirageCore
import Testing
@testable import MirageShell

@MainActor
@Suite("LocationSettingsController")
struct LocationSettingsControllerTests {
    private let scratch = ScratchDirectories()

    @Test func appliesLocationOnceAfterConnectionWhenEnabled() async throws {
        let store = try makeStore(
            LocationPreferences(enabled: true,
                                coordinate: LocationCoordinate(latitude: 25.0339, longitude: 121.5645)))
        let expected = try LocationCoordinate(latitude: 25.0339, longitude: 121.5645)
        var received: [LocationCoordinate] = []
        let controller = LocationSettingsController(store: store) { received.append($0) }

        let applied = await controller.applyAfterConnection()

        #expect(applied)
        #expect(received == [expected])
    }

    @Test func doesNotApplyLocationAfterConnectionWhenDisabled() async throws {
        let coordinate = try LocationCoordinate(latitude: 25.0339, longitude: 121.5645)
        let store = try makeStore(LocationPreferences(enabled: false, coordinate: coordinate))
        var received: [LocationCoordinate] = []
        let controller = LocationSettingsController(store: store) { received.append($0) }

        let applied = await controller.applyAfterConnection()

        #expect(!applied)
        #expect(received.isEmpty)
    }

    @Test func invalidCoordinateDoesNotCallGpsSender() async throws {
        let store = try makeStore(LocationPreferences())
        var sendCount = 0
        let controller = LocationSettingsController(store: store) { _ in sendCount += 1 }
        controller.latitudeText = "不是數字"
        controller.longitudeText = "121.5645"

        let applied = await controller.apply()

        #expect(!applied)
        #expect(sendCount == 0)
        #expect(controller.errorMessage == "緯度必須是數字")
    }

    @Test func corruptedSettingsFallBackToDefaultsAndReportOnce() throws {
        let directory = scratch.make("location-controller-corrupt")
        let file = directory.appendingPathComponent("location.json")
        try Data("{ damaged".utf8).write(to: file)
        let controller = LocationSettingsController(
            store: LocationSettingsStore(fileURL: file),
            sendGPS: { _ in })

        #expect(!controller.enabled)
        #expect(controller.currentCoordinate == nil)
        #expect(controller.favorites.isEmpty)
        #expect(controller.consumeLoadError() != nil)
        #expect(controller.consumeLoadError() == nil)
    }

    @Test func selectingFavoriteUpdatesCoordinatesAndAppliesIt() async throws {
        let store = try makeStore(LocationPreferences())
        let coordinate = try LocationCoordinate(latitude: 35.6812, longitude: 139.7671)
        let favorite = SavedLocation(name: "東京", coordinate: coordinate)
        var received: [LocationCoordinate] = []
        let controller = LocationSettingsController(store: store) { received.append($0) }

        await controller.selectFavorite(favorite)

        #expect(controller.currentCoordinate == coordinate)
        #expect(received == [coordinate])
    }

    private func makeStore(_ preferences: LocationPreferences) throws -> LocationSettingsStore {
        let directory = scratch.make("location-controller")
        let store = LocationSettingsStore(fileURL: directory.appendingPathComponent("location.json"))
        try store.save(preferences)
        return store
    }
}
