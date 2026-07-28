import Metal

/// 鏡像繪製用的 Metal pipeline：把一張任意尺寸的來源 texture 取樣繪製到任意尺寸的目標。
///
/// **為什麼不用 `blit.copy`**：blit 要求來源與目的尺寸**完全相等**。而來源尺寸是 emulator
/// 決定的——`streamScreenshot` 的 proto 縮放合約是 can-be-less，實測請求 562x1248 會回
/// 561x1248（奇數）。把顯示路徑的正確性押在「emulator 回的尺寸剛好等於 drawable 尺寸」上，
/// 等於把一個我們控制不了的變數放進不變式裡；實測結果是 30 秒收到 1080 幀、一幀都沒畫出來，
/// 畫面全黑（見 `docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §7）。
///
/// 取樣繪製讓兩邊尺寸徹底無關：縮放由 GPU 的取樣器免費完成，長寬比則由
/// `MirrorContainerView` 的 letterbox 保證（它依實際幀尺寸擺放 `MirrorMTKView`）。
/// 這消除的是問題類別本身，不是再補一個尺寸相符的分支。
enum MirrorShaders {
    /// 全螢幕三角形 + 取樣。刻意不用 quad——三角形省掉頂點緩衝與索引，
    /// `vertex_id` 就能算出覆蓋整個裁剪空間的三個點。
    ///
    /// UV 的 y 取 `1 - p.y`：Metal 的 NDC 原點在下，texture 座標原點在上，兩者 y 相反。
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut {
        float4 pos [[position]];
        float2 uv;
    };

    vertex VOut mirage_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut out;
        out.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);
        return out;
    }

    fragment float4 mirage_fragment(VOut in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    sampler smp [[sampler(0)]]) {
        return src.sample(smp, in.uv);
    }
    """

    /// 在 runtime 編譯上面那段。SPM 沒有可靠的 `.metal` 編譯整合，而這段 shader 短到
    /// 編譯成本可以忽略，且只在 `Renderer` 建構時做一次。失敗回傳 nil——呼叫端
    /// （`Renderer.init?`）據此降級，不讓 App 因為 shader 建不起來而崩潰。
    static func makePipeline(device: MTLDevice, pixelFormat: MTLPixelFormat)
        -> MTLRenderPipelineState? {
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let vertexFunction = library.makeFunction(name: "mirage_vertex"),
              let fragmentFunction = library.makeFunction(name: "mirage_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// 線性取樣：來源與目的尺寸幾乎永遠不等（視窗大小任意、幀尺寸由 emulator 決定），
    /// 最近鄰會在縮放時產生明顯鋸齒。`clampToEdge` 避免邊緣取樣到對側像素。
    static func makeSampler(device: MTLDevice) -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: descriptor)
    }
}
