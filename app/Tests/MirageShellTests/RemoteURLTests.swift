import CoreImage
import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct RemoteURLTests {
    private let token = PairingToken(value: "00112233445566778899aabbccddeeff")!

    @Test func buildsHttpURLWithTokenQuery() {
        #expect(RemoteURL.build(host: "192.168.1.61", port: 8765, token: token)
                == "http://192.168.1.61:8765/?t=00112233445566778899aabbccddeeff")
    }

    /// Wi-Fi（en*）排最前面，Tailscale（utun*）其次，虛擬橋接最後；同類保持原順序。
    @Test func ordersWifiThenTailscaleThenOthers() {
        let list = [
            HostAddress(interface: "bridge100", ip: "192.168.139.3"),
            HostAddress(interface: "utun8", ip: "100.119.248.33"),
            HostAddress(interface: "en1", ip: "10.0.0.5"),
            HostAddress(interface: "en0", ip: "192.168.1.61"),
        ]
        #expect(HostAddresses.ordered(list).map(\.interface) == ["en1", "en0", "utun8", "bridge100"])
        #expect(HostAddresses.ordered([]).isEmpty)
    }

    @Test func allURLsFollowAddressOrder() {
        let list = [HostAddress(interface: "utun8", ip: "100.1.1.1"), HostAddress(interface: "en0", ip: "192.168.1.61")]
        #expect(RemoteURL.all(addresses: list, port: 9000, token: token) == [
            "http://192.168.1.61:9000/?t=00112233445566778899aabbccddeeff",
            "http://100.1.1.1:9000/?t=00112233445566778899aabbccddeeff",
        ])
    }

    /// `current()` 讀真實介面：只能斷言結構（IPv4 點分、非 127.*），不能斷言內容。
    @Test func currentAddressesAreIPv4NonLoopback() {
        let list = HostAddresses.current(probe: { _ in nil })
        #expect(list.allSatisfy { $0.ip.split(separator: ".").count == 4 })
        #expect(list.allSatisfy { !$0.ip.hasPrefix("127.") })
        #expect(list.allSatisfy { !$0.interface.isEmpty })
    }

    /// 產出的 QR 用 CoreImage 自己的偵測器解回來，內容一字不差。
    @Test func qrRoundTripsThroughCIDetector() throws {
        let url = RemoteURL.build(host: "192.168.1.61", port: 8765, token: token)
        let image = try #require(QRCodeImage.ciImage(url, side: 200))
        #expect(image.extent.width == 200)
        #expect(image.extent.height == 200)
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let decoded = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(decoded == [url])
        let nsImage = try #require(QRCodeImage.make(url, side: 200))
        #expect(nsImage.size.width == 200)
    }
    @Test func invalidOrTooSmallQRSizeIsRejected() {
        #expect(QRCodeImage.ciImage("test", side: 0) == nil)
        #expect(QRCodeImage.ciImage("test", side: -1) == nil)
        #expect(QRCodeImage.ciImage("test", side: .infinity) == nil)
        #expect(QRCodeImage.ciImage("test", side: 1) == nil)
    }

}
