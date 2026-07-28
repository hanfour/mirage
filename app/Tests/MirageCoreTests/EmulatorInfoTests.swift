import Testing
@testable import MirageCore

/// guest 實體解析度的解析——觸控座標換算的唯一權威來源。
///
/// 為什麼重要：proto 明載 `Touch.x/y` 是 "physical location on the screen"，也就是
/// guest 的實體螢幕座標（本機實測 1080x2400），**與串流影像尺寸無關**。而 App 層原本
/// 拿串流幀尺寸（540x1200）去換算，於是每一次點擊都落在目標位置的左上一半處。
/// 實測證據：送 `Touch(x=270, y=600)`，`pointer_location` 疊層的十字線精確落在
/// (270, 599)——若座標系是串流影像，該落在 (540, 1200)。
@Suite struct EmulatorInfoTests {
    @Test func parsesLcdSizeFromHardwareConfig() {
        let size = EmulatorInfo.displaySize(hardwareConfig: [
            "hw.lcd.width": "1080", "hw.lcd.height": "2400", "hw.lcd.density": "420",
        ])
        #expect(size?.w == 1080)
        #expect(size?.h == 2400)
    }

    /// 缺鍵、空值、非數字、非正數一律回 nil——寧可讓上層明確知道「拿不到解析度」，
    /// 也不要回一個看似合理的預設值讓觸控靜默偏掉（那正是這個 bug 潛伏那麼久的原因）。
    @Test func rejectsMissingOrUnusableValues() {
        #expect(EmulatorInfo.displaySize(hardwareConfig: [:]) == nil)
        #expect(EmulatorInfo.displaySize(hardwareConfig: ["hw.lcd.width": "1080"]) == nil)
        #expect(EmulatorInfo.displaySize(hardwareConfig: [
            "hw.lcd.width": "", "hw.lcd.height": "2400"]) == nil)
        #expect(EmulatorInfo.displaySize(hardwareConfig: [
            "hw.lcd.width": "abc", "hw.lcd.height": "2400"]) == nil)
        #expect(EmulatorInfo.displaySize(hardwareConfig: [
            "hw.lcd.width": "0", "hw.lcd.height": "2400"]) == nil)
        #expect(EmulatorInfo.displaySize(hardwareConfig: [
            "hw.lcd.width": "-1080", "hw.lcd.height": "2400"]) == nil)
    }

    /// 解析度拿不到時 `EmulatorInfo.display` 為 nil，而觸控注入必須據此**靜默不送**——
    /// 送出一個用錯尺寸換算的座標，比不送更糟：畫面有反應但點在錯的地方，而使用者
    /// 會以為是遊戲的問題。
    @Test func infoCarriesVersionAndOptionalDisplay() {
        let known = EmulatorInfo(version: "37.2.1.0", display: (w: 1080, h: 2400))
        #expect(known.version == "37.2.1.0")
        #expect(known.display?.w == 1080)

        let unknown = EmulatorInfo(version: "37.2.1.0", display: nil)
        #expect(unknown.display == nil)
        #expect(known != unknown)
    }
}
