public enum SpeechAudioConverter {
    /// 來源是 16kHz 單聲道升頻，語音頻帶遠低於 8kHz，沒有高頻內容可混疊，
    /// 因此不做抗鋸齒濾波；若改用真實 48kHz 音源，必須重新檢視這個假設。
    public static func monoAt16k(_ interleavedStereo48k: [Float]) -> [Float] {
        // 落單樣本不是完整 frame，捨棄才能避免左右聲道錯位。
        let frameCount = interleavedStereo48k.count / 2
        // 每包約 557 個 frame，最多捨棄 2 個不影響辨識；跨呼叫保留餘數
        // 會引入狀態，因此只處理完整的三個 frame 組，維持純函式。
        let outputCount = frameCount / 3
        return (0..<outputCount).map { index in
            let offset = index * 6
            return (interleavedStereo48k[offset] + interleavedStereo48k[offset + 1]) / 2
        }
    }
}
