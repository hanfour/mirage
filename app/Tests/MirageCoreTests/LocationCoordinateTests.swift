import Testing
@testable import MirageCore

@Suite("LocationCoordinate")
struct LocationCoordinateTests {
    @Test func acceptsLatitudeAndLongitudeBoundaries() throws {
        let southwest = try LocationCoordinate.parse(latitude: "-90", longitude: "-180")
        let northeast = try LocationCoordinate.parse(latitude: "90", longitude: "180")

        #expect(southwest.latitude == -90)
        #expect(southwest.longitude == -180)
        #expect(northeast.latitude == 90)
        #expect(northeast.longitude == 180)
    }

    @Test func rejectsOutOfRangeAndNonNumericValues() {
        #expect(validationError(latitude: "-90.01", longitude: "0") == .latitudeOutOfRange)
        #expect(validationError(latitude: "0", longitude: "180.01") == .longitudeOutOfRange)
        #expect(validationError(latitude: "north", longitude: "0") == .latitudeNotNumber)
        #expect(validationError(latitude: "0", longitude: "east") == .longitudeNotNumber)
    }

    @Test func rejectsNonFiniteValues() {
        #expect(validationError(latitude: "nan", longitude: "0") == .latitudeOutOfRange)
        #expect(validationError(latitude: "0", longitude: "infinity") == .longitudeOutOfRange)
    }

    private func validationError(latitude: String, longitude: String) -> LocationCoordinateError? {
        do {
            _ = try LocationCoordinate.parse(latitude: latitude, longitude: longitude)
            return nil
        } catch let error as LocationCoordinateError {
            return error
        } catch {
            return nil
        }
    }
}
