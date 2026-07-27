import Foundation

public protocol DisplayTransport: Sendable {
    func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error>
}

public enum TransportError: Error, Equatable {
    case unavailable(String)      // 可重連（UNAVAILABLE 等）
    case invalidRequest(String)   // fail fast，不重連
    /// MMAP 掛載成功但 host 寫入端無作用 → 換一條 transport。兩種成因：前 3 幀全零，
    /// 或映射區在探測完成前串流就自然結束（見 MmapBlankProbe.endedWithoutContent）。
    /// 與上面兩者語意正交：既不重連也不 fail fast，而是降級。
    case mmapUnusable(String)
}
