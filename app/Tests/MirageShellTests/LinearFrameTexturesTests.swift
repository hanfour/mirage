import Metal
import Testing
@testable import MirageShell

@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "需要 Metal 裝置"))
struct LinearFrameTexturesTests {
    private let device = MTLCreateSystemDefaultDevice()!

    /// 奇數寬度要補齊每列對齊，讀回來的像素要與上傳的一致。
    @Test func oddWidthUploadReadsBackExactly() throws {
        let frames = LinearFrameTextures(device: device)
        let width = 3, height = 2
        let pixels: [UInt8] = (0..<(width * height * 4)).map { UInt8($0 * 7 % 251) }
        let uploaded = pixels.withUnsafeBytes { frames.upload($0, width: width, height: height) }
        #expect(uploaded)
        let texture = try #require(frames.texture)
        var readBack = [UInt8](repeating: 0, count: pixels.count)
        texture.getBytes(&readBack, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        #expect(readBack == pixels)
    }

    /// 三組都在被 GPU 使用（或是目前顯示的那組）時拒絕上傳，GPU 完成後恢復。
    @Test func refusesUploadWhileAllSlotsAreInUse() throws {
        let frames = LinearFrameTextures(device: device)
        let queue = try #require(device.makeCommandQueue())
        let pixels = [UInt8](repeating: 9, count: 4 * 4 * 4)
        func upload() -> Bool { pixels.withUnsafeBytes { frames.upload($0, width: 4, height: 4) } }

        var buffers: [MTLCommandBuffer] = []
        for _ in 0..<3 {
            #expect(upload())
            let buffer = try #require(queue.makeCommandBuffer())
            frames.markInUse(by: buffer)
            buffers.append(buffer)
        }
        let refused = !upload()
        #expect(refused)

        for buffer in buffers { buffer.commit() }
        for buffer in buffers { buffer.waitUntilCompleted() }
        #expect(upload())
    }
}
