import Foundation

/// 活體測試的環境閘門，集中一處。
///
/// **為什麼要有這個檔**：這些條件原本在 8 個測試檔裡各寫一次
/// `ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1"`，而且全都寫成
/// `guard ... else { return }`——未設 env 時測試**回報 passed 但零斷言**。
/// 「201 tests passed」裡有 8 條是空的，而看報表的人無從得知。
///
/// 改用 `@Test(.enabled(if:))` 之後，未設 env 的測試會如實顯示為 skipped。
/// 閘門集中在這裡則是為了讓「加第九條活體測試」的人不必再複製一次字串——
/// 打錯環境變數名的後果是那條測試從此永遠不跑，而且同樣沒有任何訊號。
enum LiveGate {
    /// 需要真模擬器（`localhost:8554`）。
    static let live = ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1"

    /// 文字驗收只在明確指定的測試欄位執行；前置缺失由 live test 報錯，不假 pass。
    static let text = live && ProcessInfo.processInfo.environment["MIRAGE_LIVE_TEXT"] == "1"

    /// MMAP transport 活體：除了模擬器，還需主動選擇加入 mmap。
    /// 三道閘門是既有設計（見 `MmapStreamLiveTests` 與 `scripts/verify_mmap.sh`），此處只是搬家。
    static let mmap = live
        && ProcessInfo.processInfo.environment["MIRAGE_TRANSPORT"] == "mmap"
        && ProcessInfo.processInfo.environment["MIRAGE_LIVE_MMAP"] == "1"

    /// 音訊活體：額外一道閘門，讓覆蓋率量測指令（只設 MIRAGE_LIVE）不會無謂紅掉。
    /// 理由見 `AudioLiveTests` 的原註解與 `scripts/verify_audio.sh`。
    static let audio = live && ProcessInfo.processInfo.environment["MIRAGE_LIVE_AUDIO"] == "1"

    /// NIO 執行緒收斂稽核。獨立成一道閘門不是因為它慢，是因為它讀行程級的執行緒數，
    /// 與其他測試並行會讀到別人的執行緒。見 `ChannelTeardownTests`。
    static let threadAudit = ProcessInfo.processInfo.environment["MIRAGE_THREAD_AUDIT"] == "1"
}
