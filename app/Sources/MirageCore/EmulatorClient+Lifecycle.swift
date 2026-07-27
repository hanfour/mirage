import GRPC

// MARK: - 剪貼簿串流（Task 6/P1-b：guest → host 剪貼簿同步）
//
// 終審 Minor 3：從 EmulatorClient.swift 搬出（本體因新增 Important 1/2 修正超過
// 400 行上限，merge base 388 行，本分支一度推到 419，拆出 EmulatorClient+Input.swift
// 後回到 401——仍差 2 行沒回到約束內）。純檔案位移，行為零改變。

extension EmulatorClient {
    /// 於 step(.connectSucceeded) 後啟動（在 runConnectionLoop 的 .healthy 分支呼叫）；dropChannel 前取消。
    ///
    /// ADAPTATION (found during Task 5 verification, see task-5-report.md): the brief uses
    /// `client.streamClipboard(.init())`, the `EmulatorControllerAsyncClientProtocol` convenience
    /// method that returns only `GRPCAsyncResponseStream<ClipData>` — it discards the underlying
    /// `GRPCAsyncServerStreamingCall`. That response stream's `next()` only checks
    /// `Task.isCancelled` synchronously at the start of each call (see grpc-swift's
    /// GRPCAsyncResponseStream.swift); it never calls `.cancel()` on the real call. So cancelling
    /// `clipboardTask` does NOT interrupt an already in-flight `next()` await and does NOT resolve
    /// the pending NIO promise — verified empirically: with a real emulator holding the stream
    /// open (nothing else yields further clipboard events), `clipboardTask` never completes on its
    /// own. Using `makeStreamClipboardCall(_:)` instead returns the full `GRPCAsyncServerStreamingCall`,
    /// which has a genuine `.cancel()` (calls `self.call.cancel(promise: nil)`, resolving the
    /// in-flight promise). Storing that call lets `dropChannel()` cancel the real RPC before
    /// tearing down the channel's event-loop group, avoiding both a hang (task never finishing)
    /// and the NIO "leaking promise created" fatal crash (group shut down while a promise is
    /// still outstanding).
    func startClipboardStream() {
        guard let client = channelBox?.client else { return }
        clipboardTask?.cancel()
        let call = client.makeStreamClipboardCall(.init())
        clipboardCall = call
        // Capture only `responseStream` (explicitly `Sendable` in grpc-swift), not `call`
        // itself (non-Sendable — a data-race warning otherwise, since `Task { }` sends its
        // closure across `self`'s actor isolation).
        let stream = call.responseStream
        clipboardTask = Task { [guestClipCont] in
            do {
                for try await clip in stream {
                    if Task.isCancelled { return }
                    guestClipCont.yield(clip.text)
                }
            } catch { /* 串流斷屬正常（連線斷）；由重連迴圈處理，不在此重連 */ }
        }
    }
}
