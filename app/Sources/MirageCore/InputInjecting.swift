import Foundation

/// 輸入注入的注入縫。`EmulatorClient` 是唯一的產品實作，且它既有的兩個方法簽章
/// 與本協定完全吻合，所以 conformance 是空的、零行為改變。
///
/// **存在的理由**：`KeymapController` 原本吃具體型別 `EmulatorClient`（actor），
/// 沒有任何辦法在不建真 gRPC channel 的情況下觀察它送出了什麼——App 層的分流行為
/// 因此只能靠讀碼驗證（債務 D13 記載的問題之一）。有了這個協定，分流邏輯可以用
/// 記錄呼叫的假件逐條測試。
public protocol InputInjecting: Sendable {
    func sendTouches(_ touches: [TouchSpec]) async
    func sendKey(_ code: KeyCode, down: Bool) async
}

extension EmulatorClient: InputInjecting {}
