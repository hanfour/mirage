import Foundation

public enum LocationCoordinateError: Error, Equatable, LocalizedError, Sendable {
    case latitudeNotNumber
    case longitudeNotNumber
    case latitudeOutOfRange
    case longitudeOutOfRange

    public var errorDescription: String? {
        switch self {
        case .latitudeNotNumber: return "緯度必須是數字"
        case .longitudeNotNumber: return "經度必須是數字"
        case .latitudeOutOfRange: return "緯度必須介於 -90 到 90 度"
        case .longitudeOutOfRange: return "經度必須介於 -180 到 180 度"
        }
    }
}

public struct LocationCoordinate: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, (-90...90).contains(latitude) else {
            throw LocationCoordinateError.latitudeOutOfRange
        }
        guard longitude.isFinite, (-180...180).contains(longitude) else {
            throw LocationCoordinateError.longitudeOutOfRange
        }
        self.latitude = latitude
        self.longitude = longitude
    }

    public static func parse(latitude: String, longitude: String) throws -> LocationCoordinate {
        let latitudeText = latitude.trimmingCharacters(in: .whitespacesAndNewlines)
        let longitudeText = longitude.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let latitudeValue = Double(latitudeText) else {
            throw LocationCoordinateError.latitudeNotNumber
        }
        guard let longitudeValue = Double(longitudeText) else {
            throw LocationCoordinateError.longitudeNotNumber
        }
        return try LocationCoordinate(latitude: latitudeValue, longitude: longitudeValue)
    }

    private enum CodingKeys: String, CodingKey {
        case latitude
        case longitude
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let latitude = try container.decode(Double.self, forKey: .latitude)
        let longitude = try container.decode(Double.self, forKey: .longitude)
        do {
            try self.init(latitude: latitude, longitude: longitude)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .latitude, in: container, debugDescription: error.localizedDescription)
        }
    }
}

public struct SavedLocation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let coordinate: LocationCoordinate

    public init(id: UUID = UUID(), name: String, coordinate: LocationCoordinate) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case coordinate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container, debugDescription: "常用地點名稱不可空白")
        }
        id = try container.decode(UUID.self, forKey: .id)
        self.name = name
        coordinate = try container.decode(LocationCoordinate.self, forKey: .coordinate)
    }
}

public struct LocationPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var coordinate: LocationCoordinate?
    public var favorites: [SavedLocation]

    public init(enabled: Bool = false,
                coordinate: LocationCoordinate? = nil,
                favorites: [SavedLocation] = []) {
        self.enabled = enabled
        self.coordinate = coordinate
        self.favorites = favorites
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case coordinate
        case favorites
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        coordinate = try container.decodeIfPresent(LocationCoordinate.self, forKey: .coordinate)
        favorites = try container.decodeIfPresent([SavedLocation].self, forKey: .favorites) ?? []
    }
}

public struct LocationSettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func standard(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> LocationSettingsStore
    {
        LocationSettingsStore(fileURL: MiragePaths.locationSettingsFile(homeDirectory: homeDirectory))
    }

    public func load() throws -> LocationPreferences {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return LocationPreferences()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(LocationPreferences.self, from: data)
    }

    public func save(_ preferences: LocationPreferences) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        try data.write(to: fileURL, options: .atomic)
    }
}
