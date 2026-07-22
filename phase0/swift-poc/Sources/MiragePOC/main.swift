// phase0/swift-poc/Sources/MiragePOC/main.swift
import AppKit

// AUTHORIZED EXTENSION (part of the fps-counter extension, documented in
// task-8-report.md): stdout is fully block-buffered when not attached to a
// tty (e.g. redirected to a log file for headless verification), which
// silently withholds the "[stream] fps=..." evidence until process exit.
// Line-buffer so each fps line is flushed as it's printed.
setvbuf(stdout, nil, _IOLBF, 0)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var client: EmulatorClient!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
        view.renderer = Renderer(view: view)

        window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Mirage POC"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        do {
            client = try EmulatorClient()
        } catch {
            fatalError("無法連線 emulator gRPC：\(error)")
        }

        // 滑鼠 → guest 觸控：正規化座標換算 guest 像素
        var guestSize = (w: 1080, h: 2400)  // 首幀後更新
        view.onMouse = { [weak self] nx, ny, down in
            guard let self else { return }
            let gx = Int(nx * Double(guestSize.w))
            let gy = Int(ny * Double(guestSize.h))
            Task { await self.client.sendTap(x: gx, y: gy, down: down) }
        }

        Task {
            // AUTHORIZED EXTENSION (deviation from brief, documented in task-8-report.md):
            // lightweight fps counter — count frames and once per second print
            // "[stream] fps=<n> <w>x<h>" using a monotonic clock, reset each second.
            // This is the native-client throughput number the project's go/no-go
            // decision needs; the brief itself has no instrumentation requirement.
            var frameCount = 0
            var windowStart = DispatchTime.now()
            var lastSize = (w: 0, h: 0)
            do {
                for try await frame in client.frames() {
                    guestSize = (frame.width, frame.height)
                    view.present(frame)
                    frameCount += 1
                    lastSize = (frame.width, frame.height)
                    let now = DispatchTime.now()
                    let elapsedNs = now.uptimeNanoseconds - windowStart.uptimeNanoseconds
                    if elapsedNs >= 1_000_000_000 {
                        print("[stream] fps=\(frameCount) \(lastSize.w)x\(lastSize.h)")
                        frameCount = 0
                        windowStart = now
                    }
                }
            } catch {
                print("串流中斷：\(error)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
