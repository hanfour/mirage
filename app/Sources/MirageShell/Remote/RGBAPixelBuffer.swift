import Accelerate
import CoreVideo
import Foundation
import MirageCore

enum RGBAPixelBufferError: Error, Equatable {
    case invalidFrame
    case create(CVReturn)
    case lock(CVReturn)
    case noBaseAddress
    case permute(vImage_Error)
}

/// `Frame.rgba`（RGBA8）→ `kCVPixelFormatType_32BGRA` 的 `CVPixelBuffer`。
/// 硬體 H.264 編碼器原生吃 BGRA（2026-09-12 本機探針實測），通道置換用 vImage（SIMD），
/// 每幀一次拷貝。`CVPixelBuffer` 的每列可能有對齊填充，所以目的 `rowBytes` 要問它。
/// 每個 encoder 持有一個 pool；呼叫端用 operationLock 串列化 makeBGRA／reset。
final class RGBAPixelBuffer {
    private(set) var pool: CVPixelBufferPool?
    private var size = (0, 0)

    func reset() { pool = nil; size = (0, 0) }

    private func poolForFrame(_ frame: Frame) throws -> CVPixelBufferPool {
        if let pool, size == (frame.width, frame.height) { return pool }
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: frame.width,
            kCVPixelBufferHeightKey: frame.height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let created else { throw RGBAPixelBufferError.create(status) }
        pool = created
        size = (frame.width, frame.height)
        return created
    }

    private static let rgbaToBGRA: [UInt8] = [2, 1, 0, 3]

    func makeBGRA(from frame: Frame) throws -> CVPixelBuffer {
        guard frame.isValid else { throw RGBAPixelBufferError.invalidFrame }
        var created: CVPixelBuffer?
        let pool = try poolForFrame(frame)
        // 已歸還的 backing storage 由 pool 重用；VT 尚持有的 buffer 不會被覆寫。
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        guard status == kCVReturnSuccess, let pixelBuffer = created else {
            throw RGBAPixelBufferError.create(status)
        }
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else { throw RGBAPixelBufferError.lock(lockStatus) }
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
            return vImagePermuteChannels_ARGB8888(&src, &dst, Self.rgbaToBGRA, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError else { throw RGBAPixelBufferError.permute(error) }
        return pixelBuffer
    }
}
