// phase0/swift-poc/Sources/MiragePOC/Renderer.swift
// 畫格上屏：CPU bytes → MTLTexture → blit 到 drawable。
// drawableSize 鎖定 guest 解析度，縮放交給 CAMetalLayer；免 shader。
import Foundation
import MetalKit

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var texture: MTLTexture?

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()
        view.device = device
        view.colorPixelFormat = .rgba8Unorm
        view.framebufferOnly = false
        view.delegate = self
    }

    func upload(_ frame: Frame, into view: MTKView) {
        guard frame.width > 0, frame.height > 0,
              frame.rgba.count == frame.width * frame.height * 4 else { return }
        if texture?.width != frame.width || texture?.height != frame.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: frame.width, height: frame.height, mipmapped: false)
            desc.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: desc)
            DispatchQueue.main.async {
                view.drawableSize = CGSize(width: frame.width, height: frame.height)
                view.window?.contentAspectRatio = NSSize(width: frame.width, height: frame.height)
            }
        }
        frame.rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture?.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0, withBytes: base, bytesPerRow: frame.width * 4)
        }
    }

    func draw(in view: MTKView) {
        guard let texture,
              let drawable = view.currentDrawable,
              drawable.texture.width == texture.width,
              drawable.texture.height == texture.height,
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, to: drawable.texture)
        blit.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
