import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MirageShell

@Suite struct ScreenshotRotationTests {
    @Test(arguments: [1, 2, 3])
    func uprightPNGPreservesEveryPixelWithoutMirroring(rotation: Int) throws {
        // 面板由上到下是紅綠、藍黃、紫青；每個像素都不同，翻轉後必定比對失敗。
        let panelPixels: [[UInt8]] = [
            [255, 0, 0, 255], [0, 255, 0, 255],
            [0, 0, 255, 255], [255, 255, 0, 255],
            [255, 0, 255, 255], [0, 255, 255, 255],
        ]
        let panelPNG = try makePNG(pixels: panelPixels.flatMap { $0 }, width: 2, height: 3)
        let uprightPNG = try #require(ScreenshotRotation.uprightPNG(panelPNG, rotation: rotation))
        let source = try #require(CGImageSourceCreateWithData(uprightPNG as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let expectedWidth = rotation == 2 ? 2 : 3
        let expectedHeight = rotation == 2 ? 3 : 2
        #expect(image.width == expectedWidth)
        #expect(image.height == expectedHeight)

        // 依規格表列出輸出逐列的來源像素索引，避免依賴受測實作的換算函式。
        let expectedIndices: [Int]
        switch rotation {
        case 1: expectedIndices = [1, 3, 5, 0, 2, 4] // (W-1-y, x)
        case 2: expectedIndices = [5, 4, 3, 2, 1, 0] // (W-1-x, H-1-y)
        default: expectedIndices = [4, 2, 0, 5, 3, 1] // (y, H-1-x)
        }
        let actualPixels = try readPixels(image)
        try #require(actualPixels.count == expectedIndices.count * 4)
        for y in 0..<expectedHeight {
            for x in 0..<expectedWidth {
                let pixelIndex = y * expectedWidth + x
                let byteIndex = pixelIndex * 4
                let actual = Array(actualPixels[byteIndex..<(byteIndex + 4)])
                let expected = panelPixels[expectedIndices[pixelIndex]]
                #expect(actual == expected, "rotation=\(rotation), pixel=(\(x), \(y))")
            }
        }
    }

    private func makePNG(pixels: [UInt8], width: Int, height: Int) throws -> Data {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo, provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        let finalized = CGImageDestinationFinalize(destination)
        try #require(finalized)
        return output as Data
    }

    private func readPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = Data(count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let base = try #require(raw.baseAddress)
            let context = try #require(CGContext(
                data: base, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Array(pixels)
    }

    private var bitmapInfo: CGBitmapInfo {
        CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
}
