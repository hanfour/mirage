import Accelerate
import CoreVideo
import Foundation
import MirageCore

enum RGBAPixelBufferError: Error, Equatable {
    case invalidFrame
    case create(CVReturn)
    case noBaseAddress
    case permute(vImage_Error)
}

/// `Frame.rgba`（RGBA8）→ `kCVPixelFormatType_32BGRA` 的 `CVPixelBuffer`。
/// 硬體 H.264 編碼器原生吃 BGRA（2026-09-12 本機探針實測），通道置換用 vImage（SIMD），
/// 每幀一次拷貝。`CVPixelBuffer` 的每列可能有對齊填充，所以目的 `rowBytes` 要問它。
enum RGBAPixelBuffer {
    private static let rgbaToBGRA: [UInt8] = [2, 1, 0, 3]

    static func makeBGRA(from frame: Frame) throws -> CVPixelBuffer {
        guard frame.isValid else { throw RGBAPixelBufferError.invalidFrame }
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height,
                                         kCVPixelFormatType_32BGRA, nil, &created)
        guard status == kCVReturnSuccess, let pixelBuffer = created else {
            throw RGBAPixelBufferError.create(status)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw RGBAPixelBufferError.noBaseAddress
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let error: vImage_Error = frame.rgba.withUnsafeBytes { raw in
            guard let source = raw.baseAddress else { return vImage_Error(kvImageNullPointerArgument) }
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source),
                                    height: vImagePixelCount(frame.height),
                                    width: vImagePixelCount(frame.width),
                                    rowBytes: frame.width * 4)
            var dst = vImage_Buffer(data: base, height: vImagePixelCount(frame.height),
                                    width: vImagePixelCount(frame.width), rowBytes: rowBytes)
            return vImagePermuteChannels_ARGB8888(&src, &dst, rgbaToBGRA, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError else { throw RGBAPixelBufferError.permute(error) }
        return pixelBuffer
    }
}
