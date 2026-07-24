import Foundation
import Testing
import GRPC
import NIOPosix
@testable import MirageCore

@Suite struct SnapshotRoundTripLiveTests {
    @Test func saveThenLoadRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1" else { return }
        let boxCh = try GrpcChannelBox(host: "localhost", port: 8554)
        let snap = GrpcSnapshotService(channelBox: boxCh)
        #expect(await snap.save("mirage_suspend") == true)
        #expect(await snap.load("mirage_suspend") == true)
    }
}
