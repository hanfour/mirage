import AppKit

@MainActor
protocol ClipboardReading {
    var changeCount: Int { get }
    func plainText() -> String?
}

extension NSPasteboard: ClipboardReading {
    func plainText() -> String? { string(forType: .string) }
}

/// 輪詢 NSPasteboard.changeCount，變更且為純文字時回呼。非文字略過（spec §4.3）。
@MainActor
final class ClipboardWatcher {
    private let pasteboard: any ClipboardReading
    private var lastCount: Int
    private var timer: Timer?
    private let onChange: (String) -> Void

    init(pasteboard: any ClipboardReading = NSPasteboard.general, onChange: @escaping (String) -> Void) {
        self.pasteboard = pasteboard
        self.onChange = onChange
        self.lastCount = pasteboard.changeCount
    }

    func start() {
        // ADAPTATION (-strict-concurrency=complete): Timer's `block` parameter is
        // `@escaping @Sendable (Timer) -> Void`, but `poll()` is @MainActor-isolated
        // and mutates non-Sendable state (`lastCount`, `timer`). Capturing `self`
        // weakly keeps the closure itself free of non-Sendable mutable captures
        // (only an Optional weak reference crosses in), and `MainActor.assumeIsolated`
        // re-enters MainActor isolation synchronously — safe because Foundation
        // fires run-loop-based Timer callbacks on the main thread/main run loop.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// 供本地寫入後同步 changeCount，避免把自己剛寫入的值當成 host 變更回吐（App 層第一道防線）。
    func syncBaseline() { lastCount = pasteboard.changeCount }

    /// Timer 只負責排程；測試直接 poll，驗證 spec §4.3 的變更與純文字過濾。
    func poll() {
        let c = pasteboard.changeCount
        guard c != lastCount else { return }
        lastCount = c
        guard let s = pasteboard.plainText() else { return }  // 非文字略過
        onChange(s)
    }
}
