import MirageCore

/// 串流解析度由視窗與手機遙控兩邊的需求合併決定（`StreamDemands`）。
/// 兩邊都只回報需求，只有這裡呼叫 `client.setStreamSize`。
extension AppModel {
    func updateWindowStreamDemand(width: Int, height: Int) async {
        streamDemands.window = (w: width, h: height)
        await applyStreamDemands()
    }

    /// nil 代表手機斷線。長寬比取 guest 解析度，直橫看最近的幀（理由見 `StreamSize.aspect`）。
    func updateRemoteViewport(_ viewport: RemoteViewport?) async {
        if let viewport {
            let frame = remote?.latestFrameSize ?? (frameSize.w > 0 ? frameSize : nil)
            let aspect = StreamSize.aspect(guest: await client.displaySize, frame: frame)
            streamDemands.remote = StreamSize.fitting(viewport, aspect: aspect)
        } else {
            streamDemands.remote = nil
        }
        await applyStreamDemands()
    }

    /// 尺寸沒變就不送：`setStreamSize` 每次都會重新訂閱串流。
    private func applyStreamDemands() async {
        let size = streamDemands.request(fallback: Self.defaultStreamSize)
        guard size != (await client.requestedStreamSize) else { return }
        print("[stream] 請求 \(size.w)x\(size.h)（視窗 \(Self.describe(streamDemands.window))、手機 \(Self.describe(streamDemands.remote))）")
        await client.setStreamSize(width: size.w, height: size.h)
    }

    private static func describe(_ size: (w: Int, h: Int)?) -> String {
        size.map { "\($0.w)x\($0.h)" } ?? "無"
    }
}
