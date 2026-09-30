import Foundation
import MirageCore

enum ScreenshotCaptureResult: Equatable {
    case skipped
    case unavailable
    case png(Data)
}

enum ScreenshotCapture {
    static func request(connState: ConnState, screenshot: () async -> Data?) async -> ScreenshotCaptureResult {
        guard connState == .connected else { return .skipped }
        guard let data = await screenshot() else { return .unavailable }
        return .png(data)
    }
}
