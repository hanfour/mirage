import Foundation

/// emulator 的靜態資訊，由健康探測順手帶出（`getStatus` 本來就回傳這些，之前被丟棄）。
///
/// `display` 是 **guest 的實體螢幕解析度**，也是觸控座標換算的唯一權威來源：proto 明載
/// `Touch.x/y` 是 "physical location on the screen"，**與串流影像尺寸無關**。App 層原本
/// 拿串流幀尺寸換算（實測串流 540x1200 vs guest 1080x2400），於是每一次點擊都落在目標
/// 位置的左上一半處——見 `docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §10。
public struct EmulatorInfo: Equatable, Sendable {
    public let version: String
    /// nil = 探測回覆裡沒有可用的 `hw.lcd.*`。呼叫端必須據此**放棄注入**而非猜一個值，
    /// 理由見 `EmulatorClient.sendTap`。
    public let display: (w: Int, h: Int)?

    public init(version: String, display: (w: Int, h: Int)?) {
        self.version = version
        self.display = display
    }

    public static func == (lhs: EmulatorInfo, rhs: EmulatorInfo) -> Bool {
        lhs.version == rhs.version && lhs.display?.w == rhs.display?.w
            && lhs.display?.h == rhs.display?.h
    }

    /// 從 `getStatus` 的 `hardwareConfig` 取出 guest 實體解析度。
    ///
    /// 任何不可用的值一律回 nil——缺鍵、空字串、非數字、非正數。**刻意不給預設值**：
    /// 一個看似合理的預設（例如 1080x2400）會讓觸控在其他裝置上靜默偏掉，而這個 bug
    /// 之所以能潛伏到 Phase-1，正是因為錯誤的座標「看起來像是遊戲沒反應」。
    public static func displaySize(hardwareConfig: [String: String]) -> (w: Int, h: Int)? {
        guard let w = hardwareConfig["hw.lcd.width"].flatMap(Int.init), w > 0,
              let h = hardwareConfig["hw.lcd.height"].flatMap(Int.init), h > 0
        else { return nil }
        return (w, h)
    }
}
