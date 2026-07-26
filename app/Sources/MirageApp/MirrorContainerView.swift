import AppKit
import MirageCore

/// 黑底容器：把 MirrorMTKView 佈局成 ViewportFit 算出的置中內容矩形，黑邊即本 view 的背景色。
///
/// 同時是**視窗長寬比的唯一權威**（原本散在 MirrorMTKView.viewDidMoveToWindow 與
/// Renderer.upload 兩處，且都硬編碼 9:20）。全螢幕時 macOS 忽略 contentAspectRatio，
/// 由本 view 的 letterbox 佈局接手——視窗模式黑邊為 0，兩者同一份程式碼。
final class MirrorContainerView: NSView {
    let mirror = MirrorMTKView(frame: .zero)

    /// 目前解碼幀尺寸。由 Renderer.onFrameSize 推入；(0, 0) 代表尚未收到任何幀。
    var frameSize: (w: Int, h: Int) = (0, 0) {
        didSet {
            guard frameSize != oldValue else { return }
            needsLayout = true
            applyWindowAspect()
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

    override func layout() {
        super.layout()
        let rect = ViewportFit.fit(frame: frameSize,
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
    }

    /// 用**實際幀長寬比**鎖定視窗（取代原本硬編碼的 9:20）。尚無幀時用 9:20 當初始值，
    /// 收到第一幀（含之後遊戲轉向）會立即改寫。全螢幕期間不碰視窗尺寸——macOS 全螢幕
    /// 下視窗就是整片螢幕，設 contentAspectRatio 無效且會擾動退出全螢幕後的尺寸。
    private func applyWindowAspect() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let aspect = frameSize.w > 0 && frameSize.h > 0 ? frameSize : (w: 9, h: 20)
        window.contentAspectRatio = NSSize(width: aspect.w, height: aspect.h)
        let w = max(window.frame.width, 270)
        window.setContentSize(NSSize(width: w, height: w * CGFloat(aspect.h) / CGFloat(aspect.w)))
    }
}
