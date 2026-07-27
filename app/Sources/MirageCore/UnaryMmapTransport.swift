import Foundation

/// 實驗性傳輸：輪詢 unary getScreenshot + MMAP 檔案（零拷貝資料面）。
/// 僅 MIRAGE_TRANSPORT=unary-mmap 時由 App 層選用；預設不啟用。
public struct UnaryMmapTransport: DisplayTransport {
    private let channel: GrpcChannelBox
    private let versionString: String
    private let pollHz: Int

    public init(channel: GrpcChannelBox, versionString: String, pollHz: Int = 60) {
        self.channel = channel
        self.versionString = versionString
        self.pollHz = pollHz
    }

    public func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        guard MmapVersionGate.allows(versionString: versionString) else {
            return AsyncThrowingStream { cont in
                cont.finish(throwing: TransportError.invalidRequest(
                    "emulator \(versionString) 不支援 MMAP（<37 會崩潰），拒絕啟用"))
            }
        }
        let size = width * height * 4
        let path = NSTemporaryDirectory() + "mirage_mmap_\(width)x\(height).bin"
        let intervalNs = UInt64(1_000_000_000 / max(pollHz, 1))
        let client = channel.client
        return AsyncThrowingStream { continuation in
            let task = Task {
                FileManager.default.createFile(atPath: path, contents: Data(count: size))
                var format = Android_Emulation_Control_ImageFormat()
                format.format = .rgba8888
                format.width = UInt32(width)
                format.height = UInt32(height)
                var transport = Android_Emulation_Control_ImageTransport()
                transport.channel = .mmap
                transport.handle = "file://\(path)"
                format.transport = transport
                do {
                    while !Task.isCancelled {
                        _ = try await client.getScreenshot(format)
                        guard let data = FileManager.default.contents(atPath: path),
                              data.count == size else {
                            throw TransportError.unavailable("mmap 檔讀取失敗")
                        }
                        continuation.yield(Frame(width: width, height: height, rgba: data))
                        try await Task.sleep(nanoseconds: intervalNs)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
