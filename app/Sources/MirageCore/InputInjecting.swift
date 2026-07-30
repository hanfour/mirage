import Foundation

/// 輸入注入的注入縫。`EmulatorClient` 是唯一的產品實作，且它既有的兩個方法簽章
/// 與本協定完全吻合，所以 conformance 是空的、零行為改變。
///
/// **存在的理由**：`KeymapController` 原本吃具體型別 `EmulatorClient`（actor），
/// 沒有任何辦法在不建真 gRPC channel 的情況下觀察它送出了什麼——App 層的分流行為
/// 因此只能靠讀碼驗證（債務 D13 記載的問題之一）。有了這個協定，分流邏輯可以用
/// 記錄呼叫的假件逐條測試。
/// **`sendTap` 為什麼也在裡面**（2026-07-30，D6 連帶修掉 D21）：這道縫原本只涵蓋
/// `sendTouches`/`sendKey`，於是 `MirrorView.Coordinator` 只能吃具體型別 `EmulatorClient`，
/// 「無 profile 退回直接 tap」（spec §7 驗收 4，P1-a 不回歸的核心保證）零自動化涵蓋，
/// 同一個模組還並存兩套注入慣例。修 D6 時 tap 必須跟其他輸入走**同一條** `InputQueue`
/// ——不同佇列之間沒有順序可言——所以這個缺口非補不可。
public protocol InputInjecting: Sendable {
    func sendTouches(_ touches: [TouchSpec]) async
    func sendKey(_ code: KeyCode, down: Bool) async
    func sendTap(nx: Double, ny: Double, down: Bool) async
}

extension EmulatorClient: InputInjecting {}
