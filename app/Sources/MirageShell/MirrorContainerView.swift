import AppKit
import MirageCore

/// 黑底容器：把 MirrorMTKView 佈局成 ViewportFit 算出的置中內容矩形，黑邊即本 view 的背景色。
///
/// 同時是**視窗長寬比的唯一權威**（原本散在 MirrorMTKView.viewDidMoveToWindow 與
/// Renderer.upload 兩處，且都硬編碼 9:20）。全螢幕時 macOS 忽略 contentAspectRatio，
/// 由本 view 的 letterbox 佈局接手——視窗模式黑邊為 0，兩者同一份程式碼。
final class MirrorContainerView: NSView {
    let mirror = MirrorMTKView(frame: .zero)

    // 終審 Minor 3：退出全螢幕後重新套用長寬比用的觀察者權杖。ADAPTATION（比照
    // MouseCapture.resignObserver 的既有前例）：NotificationCenter 的 block-based observer
    // 型別是 non-Sendable 的 NSObjectProtocol，而本類別（NSView 子類別）的 deinit 在
    // Swift 5 語言模式下是 nonisolated——讀取一個 MainActor-isolated 且非 Sendable 的欄位
    // 會被編譯器擋下。這顆權杖只在 MainActor（viewDidMoveToWindow）寫入、deinit 時讀一次，
    // 沒有真正的資料競爭，`nonisolated(unsafe)` 如實反映這件事。
    private nonisolated(unsafe) var exitFullScreenObserver: NSObjectProtocol?

    /// 目前解碼幀尺寸。由 Renderer.onFrameSize 推入；(0, 0) 代表尚未收到任何幀。
    var frameSize: (w: Int, h: Int) = (0, 0) {
        didSet {
            guard frameSize != oldValue else { return }
            needsLayout = true
            applyWindowAspect()
        }
    }
    var displayRotation = 0 {
        didSet {
            guard displayRotation != oldValue else { return }
            needsLayout = true
            applyWindowAspect(previousRotation: oldValue)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(mirror)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let exitFullScreenObserver {
            NotificationCenter.default.removeObserver(exitFullScreenObserver)
        }
    }

    override func layout() {
        super.layout()
        let rect = ViewportFit.fit(frame: DisplayRotation.upright(size: frameSize,
                                                                  rotation: displayRotation),
                                   in: (w: Int(bounds.width), h: Int(bounds.height)))
        // 尚未收到幀（或視窗尺寸為 0）：先鋪滿，避免第一幀前出現 0×0 的 drawable。
        guard rect.width > 0, rect.height > 0 else {
            mirror.frame = bounds
            return
        }
        mirror.frame = NSRect(x: CGFloat(rect.x), y: CGFloat(rect.y),
                              width: CGFloat(rect.width), height: CGFloat(rect.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowAspect()
        observeFullScreenExit()
    }

    /// 終審 Minor 3：`applyWindowAspect()` 在全螢幕期間提早 return（見該方法）；若 guest
    /// 在全螢幕期間轉向，退出全螢幕後 `contentAspectRatio` 會停在舊比例——沒有任何既有
    /// 路徑會在退出後重算。刻意不放進 `layout()`：`layout()` 在一般 resize／letterbox
    /// 重排（含 `applyWindowAspect()` 自己呼叫的 `setContentSize` 觸發的那一輪）都會被
    /// 呼叫，若在裡面無條件呼叫 `applyWindowAspect()`，`setContentSize()` 觸發新一輪
    /// `layout()` 又再呼叫一次，會形成不必要的重排迴圈。改用
    /// `didExitFullScreenNotification`：只在真正「退出全螢幕」那一刻觸發一次，
    /// `setContentSize` 本身不會再送出這個通知，沒有迴圈風險。
    private func observeFullScreenExit() {
        if let exitFullScreenObserver {
            NotificationCenter.default.removeObserver(exitFullScreenObserver)
            self.exitFullScreenObserver = nil
        }
        guard let window else { return }
        exitFullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            // 比照 MouseCapture.resignObserver 的既有前例：queue: .main 保證這個 block
            // 一定在 main run loop 執行，用 assumeIsolated 同步呼叫，不必等 Task 跳轉
            // （避免退出全螢幕與長寬比修正之間多一個 runloop tick 的空窗）。
            MainActor.assumeIsolated { self?.applyWindowAspect() }
        }
    }

    /// 用**實際幀長寬比**鎖定視窗（取代原本硬編碼的 9:20）。尚無幀時用 9:20 當初始值，
    /// 收到第一幀（含之後遊戲轉向）會立即改寫。全螢幕期間不碰視窗尺寸——macOS 全螢幕
    /// 下視窗就是整片螢幕，設 contentAspectRatio 無效且會擾動退出全螢幕後的尺寸。
    private func applyWindowAspect(previousRotation: Int? = nil) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let panelSize = frameSize.w > 0 && frameSize.h > 0 ? frameSize : (w: 9, h: 20)
        let aspect = DisplayRotation.upright(size: panelSize, rotation: displayRotation)
        let oldFrame = window.frame
        let oldContentSize = window.contentView?.bounds.size ?? .zero
        window.contentAspectRatio = NSSize(width: aspect.w, height: aspect.h)
        let swappedOrientation = previousRotation.map {
            $0.isMultiple(of: 2) != displayRotation.isMultiple(of: 2)
        } ?? false
        let widthBefore = swappedOrientation && oldContentSize.height > 0
            ? oldContentSize.height : oldFrame.width
        let ratio = CGFloat(aspect.w) / CGFloat(aspect.h)
        let minimumWidth = aspect.w > aspect.h ? 270 * ratio : 270
        let width = max(widthBefore, minimumWidth)
        let topCenter = CGPoint(x: oldFrame.midX, y: oldFrame.maxY)
        window.setContentSize(NSSize(width: width, height: width / ratio))

        var frame = window.frame
        frame.origin = CGPoint(x: topCenter.x - frame.width / 2,
                               y: topCenter.y - frame.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = frame.width >= visible.width
                ? visible.minX : min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = frame.height >= visible.height
                ? visible.minY : min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: false)
    }
}
