import Metal

/// 取樣繪製：把任意尺寸的來源 texture 畫到任意尺寸的目標，縮放交給 GPU 的取樣器。
///
/// **為什麼不綁 `@MainActor`**：繪製只需要 device/queue/pipeline/sampler，這些 Metal 物件
/// 本身就是執行緒安全的。`Renderer` 因為持有 `MTKView` 必須是 `@MainActor`，但把繪製留在
/// 它裡面會逼測試也在 MainActor 上跑——而測試要讀回繪製結果就得 `waitUntilCompleted()`
/// 同步等 GPU，在 MainActor 上阻塞會讓整個測試程序的 async 工作全部停擺（實測：完整套件
/// 30 條測試卡死不動，同一條單獨跑卻 0.4 秒通過）。分開之後測試完全不碰 MainActor。
///
/// **為什麼不用 `blit.copy`**：blit 要求來源與目的尺寸完全相等，而來源尺寸是 emulator
/// 決定的——`streamScreenshot` 的 proto 縮放合約是 can-be-less，實測請求 562x1248 會回
/// 561x1248（奇數）。把顯示的正確性押在一個我們控制不了的變數上，實測結果就是 30 秒收到
/// 1080 幀、一幀都沒畫出來（見 `docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §7）。
final class MirrorBlitter: @unchecked Sendable {
    // @unchecked：MTLCommandQueue／PipelineState／SamplerState 依 Metal 的合約是執行緒
    // 安全的，但型別本身未標 Sendable。三者建構後皆為唯讀，不存在需要同步的可變狀態。
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat = .rgba8Unorm) {
        guard let queue = device.makeCommandQueue(),
              let pipeline = MirrorShaders.makePipeline(device: device, pixelFormat: pixelFormat),
              let sampler = MirrorShaders.makeSampler(device: device) else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
    }

    func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }

    /// 把 `source` 取樣繪製進 `target`。兩者尺寸無需有任何關係——那正是本型別存在的理由。
    func encode(_ source: MTLTexture, into target: MTLTexture, on buffer: MTLCommandBuffer,
                rotation: UInt32 = 0) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare   // 三角形覆蓋全畫面，不必先清
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var displayRotation = rotation
        encoder.setFragmentBytes(&displayRotation, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// 繪製並等到 GPU 完成——供測試讀回結果。產品路徑走 `Renderer.draw(in:)`，
    /// 它要 present，不需要等。
    ///
    /// **用 completion handler 而非 `waitUntilCompleted()`**：後者是同步阻塞，會佔住一條
    /// Swift concurrency 的 cooperative pool 執行緒。這個測試套件裡已經有好幾條測試在真
    /// OS 執行緒上忙等（`depthNeverGoesNegativeUnderThreadedContention` 等），再多一條阻塞
    /// 就會把 pool 逼到飢餓——實測症狀是整個測試程序停擺、30 條 async 測試永遠跑不完，
    /// 而同一條測試單獨跑 0.4 秒就過。continuation 版本完全不佔執行緒。
    func render(_ source: MTLTexture, into target: MTLTexture) async {
        guard let buffer = makeCommandBuffer() else { return }
        encode(source, into: target, on: buffer)
        await withCheckedContinuation { continuation in
            buffer.addCompletedHandler { _ in continuation.resume() }
            buffer.commit()
        }
    }
}
