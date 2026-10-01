import Foundation
import Metal

/// 以 linear 排列的 MTLBuffer 當 texture 的儲存空間，CPU 上傳只剩逐列複製。
///
/// 用一般 texture 時 `replace(region:)` 要由 CPU 把整幀重排成 GPU 的分塊格式（預設還會再壓縮），
/// 2026-10-01 取樣這一步佔 Mirage CPU 約三成；關掉壓縮（allowGPUOptimizedContents）只是換成
/// 重排（agxsTwiddleAddress），成本不變。linear texture 由 GPU 直接讀，CPU 不用重排。
///
/// 三組輪流使用，避免 CPU 覆寫 GPU 還在讀的那一組。每組記錄正在使用它的 command buffer 數，
/// 完成時減一；沒有空的那組時這一幀不上傳，畫面沿用上一幀。
final class LinearFrameTextures: @unchecked Sendable {
    private final class Slot {
        let buffer: MTLBuffer
        let texture: MTLTexture
        var inFlight = 0
        init(buffer: MTLBuffer, texture: MTLTexture) {
            self.buffer = buffer
            self.texture = texture
        }
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private var slots: [Slot] = []
    private var current: Slot?
    private var width = 0
    private var height = 0
    private var bytesPerRow = 0

    init(device: MTLDevice) { self.device = device }

    /// 目前可顯示的 texture（最後一次成功上傳的那組）。
    var texture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return current?.texture
    }

    /// 上傳一幀 RGBA。尺寸改變時重建三組。回傳 false 表示沒有空的那組或建立失敗，這一幀略過。
    func upload(_ pixels: UnsafeRawBufferPointer, width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, let base = pixels.baseAddress,
              pixels.count >= width * height * 4 else { return false }
        lock.lock()
        if width != self.width || height != self.height {
            guard rebuild(width: width, height: height) else { lock.unlock(); return false }
        }
        guard let slot = slots.first(where: { $0.inFlight == 0 && $0 !== current }) else {
            lock.unlock(); return false
        }
        let rowBytes = bytesPerRow
        lock.unlock()

        let source = width * 4
        let destination = slot.buffer.contents()
        if rowBytes == source {
            destination.copyMemory(from: base, byteCount: source * height)
        } else {
            for row in 0..<height {
                destination.advanced(by: row * rowBytes)
                    .copyMemory(from: base.advanced(by: row * source), byteCount: source)
            }
        }

        lock.lock(); current = slot; lock.unlock()
        return true
    }

    /// 這個 command buffer 會讀目前的 texture：完成前不得覆寫。
    func markInUse(by commandBuffer: MTLCommandBuffer) {
        lock.lock()
        guard let slot = current else { lock.unlock(); return }
        slot.inFlight += 1
        lock.unlock()
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); slot.inFlight -= 1; self.lock.unlock()
        }
    }

    /// 呼叫端已持有 lock。
    private func rebuild(width: Int, height: Int) -> Bool {
        let alignment = device.minimumLinearTextureAlignment(for: .rgba8Unorm)
        let rowBytes = (width * 4 + alignment - 1) / alignment * alignment
        var built: [Slot] = []
        for _ in 0..<3 {
            guard let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared) else {
                return false
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let texture = buffer.makeTexture(descriptor: desc, offset: 0, bytesPerRow: rowBytes) else {
                return false
            }
            built.append(Slot(buffer: buffer, texture: texture))
        }
        slots = built
        current = nil
        self.width = width
        self.height = height
        bytesPerRow = rowBytes
        return true
    }
}
