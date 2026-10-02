import AppKit
import MirageCore

// 更正（2026-07-29，D1）：下面這段描述的根因**已經修掉了**。
// `GrpcChannelBox.deinit` 不再呼叫阻塞式的 `syncShutdownGracefully()`；
// `EmulatorClient.dropChannel()` 改為顯式呼叫 `GrpcChannelBox.shutdown()`——
// 先 `channel.close()` 再回呼式 `group.shutdownGracefully(queue:)`，全程不阻塞。
// 那行 `Cannot schedule tasks on an EventLoop that has already shut down`
// 在修正後的連跑 5 次完整套件中出現 0 次（修正前：卡死 3 次，通過的 2 次各印 3 行與 5 行）。
//
// 因此下面這套 semaphore + 200ms drain **不再是必要的**，只是多餘的保險。
// 刻意保留未動：移除它會改變 ⌘Q 路徑的行為，而 GUI App 在 headless 下驅動不了
// applicationWillTerminate，無法驗證——沒有驗證就不改。要拆的話請連同
// `AppModel.shutdown()` 的 `Task.sleep(200ms)` 一起，並實機驗一次 ⌘Q。
//
// 以下為原始說明，保留以記錄當初為何這樣寫：
//
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
// before allowing the process to actually exit. `AppModel.shutdown()`
// (Sources/MirageShell/AppModel.swift) does exactly that.
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

    /// AppModel 在這裡建立：SwiftUI 不再有持有它的場景。背景模式在最早的時間點換成 accessory，
    /// Dock 圖示從頭就不出現。
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if model == nil {
                model = AppModel(locationSettingsStore: .standard())
            }
            guard model?.launchPreferences.effectiveBackgroundMode ?? false else { return }
            (NSApp as NSApplication?)?.setActivationPolicy(LaunchPreferences.launchActivationPolicy(backgroundMode: true))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let model else { return }
            Task { @MainActor in await model.launch() }
        }
    }

    /// 點 Dock 圖示：原本由 SwiftUI `Window` 場景叫回隱藏的視窗，改成 AppKit 視窗後要自己處理。
    /// 回傳 false，避免 SwiftUI 另外開出空的 Settings 視窗。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { model?.wake() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            AppLifecycle.diagnose("lastWindowPolicy", window: nil,
                                  receiver: NSStringFromClass(type(of: self)),
                                  result: String(LifecyclePolicy.terminateAfterLastWindowClosed))
        }
        return LifecyclePolicy.terminateAfterLastWindowClosed
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            model?.testControlChannel?.stop()
            model?.gamepadMonitor?.stop()
            if ProcessInfo.processInfo.environment["MIRAGE_CONN_LOG"] == "1" {
                AppLifecycle.diagnose("applicationWillTerminate", window: nil)
                for window in (NSApp as NSApplication?)?.windows ?? [] {
                    AppLifecycle.diagnose("terminate-window", window: window)
                }
            }
        }
        guard let model else { return }
        // 終審 Minor 5（AudioPlayer.stop() 死碼）：呼叫點刻意放在這裡、同步呼叫，
        // 不是塞進 `AppModel.swift` 的 `model.shutdown()`（`nonisolated`，刻意設計成能在 MainActor 之外
        // 的執行緒跑到完，因為呼叫端要在被 semaphore 卡住的主執行緒上等它，見該方法註解）。
        // 若改成在 shutdown() 裡 `await MainActor.run { audioPlayer?.stop() }`，這一跳需要
        // 排進 MainActor 的序列 executor——也就是主執行緒的 run loop；但主執行緒這時已經
        // 被下面的 `sema.wait()` 同步卡住、不會再抽出時間處理任何排進來的工作，會造成
        // 永久死鎖（quit 卡死、需強制結束），恰好加重 AppModel.shutdown() 註解記載的既有
        // NIO teardown race 那類風險。改在這裡（AppKit 保證 applicationWillTerminate
        // 跑在主執行緒、且此刻主執行緒還沒被 semaphore 卡住）用 assumeIsolated 同步呼叫，
        // 完全不牽動 shutdown() 的既有路徑。
        MainActor.assumeIsolated { model.audioPlayer?.stop() }
        MainActor.assumeIsolated { model.instanceManagerPresentation.launcher?.stopAllOwnedForTermination() }
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            await model.shutdown()
            sema.signal()
        }
        sema.wait()
    }
}
