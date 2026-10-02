import Foundation
import MirageCore
import Observation

@MainActor
@Observable
final class LocationSettingsController {
    var enabled: Bool {
        didSet { persist() }
    }
    var latitudeText: String {
        didSet { persist() }
    }
    var longitudeText: String {
        didSet { persist() }
    }
    var favoriteName = ""
    var favorites: [SavedLocation] {
        didSet { persist() }
    }
    var applyMessage: String?
    var errorMessage: String?

    @ObservationIgnored var onStatusChange: (@MainActor () -> Void)?
    @ObservationIgnored private let store: LocationSettingsStore?
    @ObservationIgnored private let sendGPS: @MainActor (LocationCoordinate) async throws -> Void
    @ObservationIgnored private var preferences: LocationPreferences
    @ObservationIgnored private var pendingLoadError: String?
    @ObservationIgnored private var updatingDraft = false

    init(
        store: LocationSettingsStore? = nil,
        sendGPS: @escaping @MainActor (LocationCoordinate) async throws -> Void
    ) {
        self.store = store
        self.sendGPS = sendGPS
        if let store {
            do {
                preferences = try store.load()
                pendingLoadError = nil
            } catch {
                preferences = LocationPreferences()
                pendingLoadError = error.localizedDescription
            }
        } else {
            preferences = LocationPreferences()
            pendingLoadError = nil
        }
        enabled = preferences.enabled
        latitudeText = preferences.coordinate.map { String($0.latitude) } ?? ""
        longitudeText = preferences.coordinate.map { String($0.longitude) } ?? ""
        favorites = preferences.favorites
    }

    var currentCoordinate: LocationCoordinate? {
        try? LocationCoordinate.parse(latitude: latitudeText, longitude: longitudeText)
    }

    var menuStatus: String {
        guard enabled else { return "位置：模擬器預設" }
        guard let coordinate = preferences.coordinate else { return "位置：自訂（未設定）" }
        if let favorite = favorites.first(where: { $0.coordinate == coordinate }) {
            return "位置：自訂（\(favorite.name)）"
        }
        return "位置：自訂（\(coordinate.latitude), \(coordinate.longitude)）"
    }

    func consumeLoadError() -> String? {
        defer { pendingLoadError = nil }
        return pendingLoadError
    }

    @discardableResult
    func apply() async -> Bool {
        applyMessage = nil
        errorMessage = nil
        let coordinate: LocationCoordinate
        do {
            coordinate = try LocationCoordinate.parse(latitude: latitudeText, longitude: longitudeText)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        guard enabled else {
            errorMessage = "請先啟用自訂位置"
            return false
        }
        persist(coordinate: coordinate)
        do {
            try await sendGPS(coordinate)
            applyMessage = "已套用"
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func applyAfterConnection() async -> Bool {
        guard enabled else { return false }
        guard let coordinate = preferences.coordinate else {
            print("[location] 連線時套用失敗：沒有有效的座標")
            return false
        }
        do {
            try await sendGPS(coordinate)
            return true
        } catch {
            print("[location] 連線時套用失敗：\(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func saveFavorite() -> Bool {
        errorMessage = nil
        let name = favoriteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "請輸入常用地點名稱"
            return false
        }
        let coordinate: LocationCoordinate
        do {
            coordinate = try LocationCoordinate.parse(latitude: latitudeText, longitude: longitudeText)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        favorites.append(SavedLocation(name: name, coordinate: coordinate))
        favoriteName = ""
        return true
    }

    func selectFavorite(_ favorite: SavedLocation) async {
        enabled = true
        setDraftCoordinate(favorite.coordinate)
        _ = await apply()
    }

    func removeFavorite(id: UUID) {
        favorites.removeAll { $0.id == id }
    }

    private func setDraftCoordinate(_ coordinate: LocationCoordinate) {
        updatingDraft = true
        latitudeText = String(coordinate.latitude)
        longitudeText = String(coordinate.longitude)
        updatingDraft = false
        persist(coordinate: coordinate)
    }

    private func persist(coordinate explicitCoordinate: LocationCoordinate? = nil) {
        guard !updatingDraft else { return }
        let coordinate = explicitCoordinate ?? currentCoordinate ?? preferences.coordinate
        preferences = LocationPreferences(enabled: enabled,
                                          coordinate: coordinate,
                                          favorites: favorites)
        guard let store else {
            onStatusChange?()
            return
        }
        do {
            try store.save(preferences)
            errorMessage = nil
        } catch {
            errorMessage = "儲存位置設定失敗：\(error.localizedDescription)"
        }
        onStatusChange?()
    }
}
