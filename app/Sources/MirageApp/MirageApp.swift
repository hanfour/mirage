import AppKit
import MirageCore
import SwiftUI

@main
struct MirageApp: App {
    @State private var model = AppModel()
    // AUTHORIZED ADDITION（Task 4 review: NIO teardown race）— see AppDelegate below.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // AUTHORIZED ADDITION (phase0 lesson — see phase0/swift-poc task-8-report.md's
    // `setvbuf` deviation): stdout is block-buffered whenever it isn't a TTY
    // (e.g. redirected to a log file, as the smoke-test harness does), so the
    // `[app] fps=N` lines Renderer prints would sit in the buffer until
    // process exit and be lost entirely on a hard `pkill`. Force line
    // buffering so each fps line flushes as soon as it's printed.
    init() {
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        WindowGroup("Mirage") {
            ZStack(alignment: .top) {
                MirrorView(client: model.client, box: model.box)
                ConnectionBanner(state: model.connState)
            }
            .frame(minWidth: 270, minHeight: 600)
            .task {
                appDelegate.model = model   // 供 applicationWillTerminate 使用
                await model.start()
            }
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let client = EmulatorClient()
    let box = LatestFrameBox()
    var connState: ConnState = .disconnected

    func start() async {
        Task { [client] in
            for await s in client.states {
                await MainActor.run { self.connState = s }
            }
        }
        await client.start(box: box, width: 540, height: 1200)
    }

    // AUTHORIZED ADDITION（Task 4 review: NIO teardown race）— see AppDelegate
    // below for the full rationale. `nonisolated` on purpose: it only touches
    // `client`, a `let`-bound Sendable actor reference, so it can run to
    // completion off the main thread/MainActor executor — required because
    // the caller (AppDelegate.applicationWillTerminate) blocks the main
    // thread on a semaphore while this runs.
    nonisolated func shutdown() async {
        await client.stop()
        try? await Task.sleep(for: .milliseconds(200))
    }
}

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
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            await model.shutdown()
            sema.signal()
        }
        sema.wait()
    }
}
