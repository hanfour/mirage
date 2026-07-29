import Foundation

public protocol DisplayTransport: Sendable {
    func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error>

    /// 顯式取消底層 RPC。語意與呼叫時機與 `AudioTransport.cancelStream()` 完全一致。
    ///
    /// **不可省略，也刻意不給 default 空實作**：`AsyncThrowingStream` 的 `onTermination`
    /// ＋ `Task.cancel()` 中斷不了已 in-flight 的 `next()`（P1-b 剪貼簿串流實證，見
    /// `EmulatorClient.startClipboardStream` 的 ADAPTATION 註解）。而 `streamScreenshot`
    /// 是**變化驅動**的——guest 畫面靜止時就沒有下一幀，`next()` 會無限期停在那裡，
    /// 跟 proto 註明「guest 靜音時 streamAudio 會無限阻塞」是同一種情境。
    ///
    /// 沒有這條，`dropChannel()` 就會帶著一個未解決的 NIO promise 去拆 EventLoopGroup，
    /// 症狀有二：乾淨跑完時每次印數行
    /// `Cannot schedule tasks on an EventLoop that has already shut down`，
    /// 或者整個行程死鎖（實測 8 條 cooperative 執行緒全部阻塞在
    /// `dropChannel → GrpcChannelBox.deinit → syncShutdownGracefully`，5 跑 2 卡）。
    ///
    /// 給 default 空實作會讓「新 transport 忘了實作」變成靜默的——這個碼庫剛因為
    /// 8 處活體測試用 `guard/return` 假裝通過而吃過同一類的虧，不再重蹈。
    func cancelStream()
}

public enum TransportError: Error, Equatable {
    case unavailable(String)      // 可重連（UNAVAILABLE 等）
    case invalidRequest(String)   // fail fast，不重連
    /// MMAP 掛載成功但 host 寫入端無作用 → 換一條 transport。兩種成因：前 3 幀全零，
    /// 或映射區在探測完成前串流就自然結束（見 MmapBlankProbe.endedWithoutContent）。
    /// 與上面兩者語意正交：既不重連也不 fail fast，而是降級。
    case mmapUnusable(String)
}
