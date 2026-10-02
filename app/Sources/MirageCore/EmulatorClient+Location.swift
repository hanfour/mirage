import GRPC

extension EmulatorClient {
    public func setLocation(_ coordinate: LocationCoordinate) async throws {
        guard let client = channelBox?.client else {
            throw EmulatorLocationError.notConnected
        }
        var state = Android_Emulation_Control_GpsState()
        state.latitude = coordinate.latitude
        state.longitude = coordinate.longitude
        state.altitude = 10
        state.satellites = 12
        state.passiveUpdate = false
        _ = try await client.setGps(state)
    }
}

public enum EmulatorLocationError: Error, Equatable, LocalizedError, Sendable {
    case notConnected

    public var errorDescription: String? {
        "模擬器尚未連線"
    }
}
