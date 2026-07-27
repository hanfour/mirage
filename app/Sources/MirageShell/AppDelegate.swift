import AppKit

// AUTHORIZED ADDITION（Task 4 review: NIO teardown race）
//
// task-4-report.md Concern 1: EmulatorClient.stop() cancels the frame pump
// and applies `.stopRequested` but does not wait for the underlying gRPC
// stream's cancellation to propagate through NIO before
// GrpcChannelBox.deinit's blocking `group.syncShutdownGracefully()` runs.
// Today this races and prints "Cannot schedule tasks on an EventLoop that
// has already shut down" on stderr; SwiftNIO's own message says this will
// be upgraded to a forced crash in a future release. On quit, AppModel and
// its EmulatorClient/GrpcChannelBox become eligible for deallocation as
// soon as the process starts tearing down — nothing today drains the
// in-flight stream cancellation first.
//
// Fix: on quit, explicitly `await client.stop()` then sleep ~200ms (empirically
// generous headroom for gRPC/NIO to finish unwinding the cancelled stream)
// before allowing the process to actually exit. `AppModel.shutdown()` above
// does exactly that.
//
// Wiring: NSApplicationDelegateAdaptor + `applicationWillTerminate` +
// a semaphore, not WindowGroup's `.onDisappear`. `.onDisappear` only fires
// when a window closes and macOS does not terminate the app when its last
// window closes by default — so it would never fire on Cmd+Q / dock "Quit"
// while the window is still open, which is the common quit path. In
// contrast `applicationWillTerminate(_:)` is NSApplication's synchronous,
// always-called pre-exit hook: returning from it is what allows the process
// to actually exit, so blocking it on a semaphore until the async drain
// finishes is the simplest way to guarantee the drain runs to completion
// before teardown.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        guard let model else { return }
        // 終審 Minor 5（AudioPlayer.stop() 死碼）：呼叫點刻意放在這裡、同步呼叫，
        // 不是塞進下面 `model.shutdown()`（`nonisolated`，刻意設計成能在 MainActor 之外
        // 的執行緒跑到完，因為呼叫端要在被 semaphore 卡住的主執行緒上等它，見該方法註解）。
        // 若改成在 shutdown() 裡 `await MainActor.run { audioPlayer?.stop() }`，這一跳需要
        // 排進 MainActor 的序列 executor——也就是主執行緒的 run loop；但主執行緒這時已經
        // 被下面的 `sema.wait()` 同步卡住、不會再抽出時間處理任何排進來的工作，會造成
        // 永久死鎖（quit 卡死、需強制結束），恰好加重 AppModel.shutdown() 註解記載的既有
        // NIO teardown race 那類風險。改在這裡（AppKit 保證 applicationWillTerminate
        // 跑在主執行緒、且此刻主執行緒還沒被 semaphore 卡住）用 assumeIsolated 同步呼叫，
        // 完全不牽動 shutdown() 的既有路徑。
        MainActor.assumeIsolated { model.audioPlayer?.stop() }
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            await model.shutdown()
            sema.signal()
        }
        sema.wait()
    }
}
