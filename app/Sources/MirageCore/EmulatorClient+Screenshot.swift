import Foundation

extension EmulatorClient {
    public func screenshotPNG() async -> Data? {
        guard let client = channelBox?.client else { return nil }
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .png
        do {
            // Omitting callOptions keeps the generated client's default options, including its auth token.
            let image = try await client.getScreenshot(format)
            return image.image.isEmpty ? nil : image.image
        } catch {
            return nil
        }
    }
}
