import CoreGraphics
import Foundation
import ImageIO
import MirageCore
import UniformTypeIdentifiers

enum ScreenshotRotation {
    static func uprightPNG(_ data: Data, rotation: Int) -> Data? {
        guard rotation != 0 else { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let sourceWidth = image.width
        let sourceHeight = image.height
        let size = DisplayRotation.upright(size: (w: sourceWidth, h: sourceHeight), rotation: rotation)
        let rowBytes = sourceWidth * 4
        var sourcePixels = Data(count: rowBytes * sourceHeight)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        let rendered = sourcePixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: sourceWidth, height: sourceHeight,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: bitmapInfo.rawValue) else { return false }
            context.translateBy(x: 0, y: CGFloat(sourceHeight))
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
            return true
        }
        guard rendered else { return nil }

        var uprightPixels = Data(count: size.w * size.h * 4)
        let rotated = uprightPixels.withUnsafeMutableBytes { targetRaw -> Bool in
            guard let target = targetRaw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return sourcePixels.withUnsafeBytes { sourceRaw -> Bool in
                guard let source = sourceRaw.bindMemory(to: UInt8.self).baseAddress else { return false }
                for y in 0..<size.h {
                    for x in 0..<size.w {
                        let sourcePoint: (x: Int, y: Int)
                        switch rotation {
                        case 1: sourcePoint = (sourceWidth - 1 - y, x)
                        case 2: sourcePoint = (sourceWidth - 1 - x, sourceHeight - 1 - y)
                        case 3: sourcePoint = (y, sourceHeight - 1 - x)
                        default: sourcePoint = (x, y)
                        }
                        let sourceIndex = (sourcePoint.y * sourceWidth + sourcePoint.x) * 4
                        let targetIndex = (y * size.w + x) * 4
                        target[targetIndex] = source[sourceIndex]
                        target[targetIndex + 1] = source[sourceIndex + 1]
                        target[targetIndex + 2] = source[sourceIndex + 2]
                        target[targetIndex + 3] = source[sourceIndex + 3]
                    }
                }
                return true
            }
        }
        guard rotated,
              let provider = CGDataProvider(data: uprightPixels as CFData),
              let uprightImage = CGImage(width: size.w, height: size.h,
                                         bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: size.w * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: bitmapInfo, provider: provider,
                                         decode: nil, shouldInterpolate: false,
                                         intent: .defaultIntent) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, uprightImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
