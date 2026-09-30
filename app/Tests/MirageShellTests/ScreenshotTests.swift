import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct ScreenshotTests {
    @Test func fileNameUsesFixedDateAndTimeZone() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let taipei = try #require(TimeZone(identifier: "Asia/Taipei"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let date = try #require(calendar.date(from: DateComponents(
            year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5)))

        #expect(ScreenshotNaming.fileName(date: date, timeZone: taipei) == "Mirage 截圖 2024-01-02 11.04.05.png")
    }

    @Test func uniqueURLIncrementsForExistingNames() {
        let directory = URL(fileURLWithPath: "/tmp/screenshots", isDirectory: true)
        let occupied: Set<String> = [
            "Mirage 截圖 2024-01-02 11.04.05.png",
            "Mirage 截圖 2024-01-02 11.04.05 (2).png",
        ]

        let url = ScreenshotNaming.uniqueURL(
            directory: directory,
            base: "Mirage 截圖 2024-01-02 11.04.05.png",
            exists: { occupied.contains($0.lastPathComponent) })

        #expect(url.lastPathComponent == "Mirage 截圖 2024-01-02 11.04.05 (3).png")
    }

    @Test func disconnectedCaptureDoesNotCallScreenshot() async {
        var calls = 0

        let result = await ScreenshotCapture.request(connState: .disconnected) {
            calls += 1
            return Data([1])
        }

        #expect(result == .skipped)
        #expect(calls == 0)
    }
}
