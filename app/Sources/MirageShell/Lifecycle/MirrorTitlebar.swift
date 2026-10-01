import AppKit

@MainActor
final class MirrorTitlebarActionsController: NSTitlebarAccessoryViewController {
    private let homeButton = MirrorTitlebarActionsController.makeButton(symbol: "square.grid.3x3.fill", label: "主畫面（⌘1）")
    private let recentsButton = MirrorTitlebarActionsController.makeButton(symbol: "rectangle.on.rectangle", label: "最近任務（⌘2）")

    var onAndroidKey: ((String) -> Void)?
    var buttons: [NSButton] { [homeButton, recentsButton] }

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        homeButton.target = self
        homeButton.action = #selector(homeTapped)
        recentsButton.target = self
        recentsButton.action = #selector(recentsTapped)
        layoutAttribute = .right
    }

    override func loadView() {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 4
        view = stack
    }

    required init?(coder: NSCoder) { nil }

    func setEnabled(_ enabled: Bool) {
        buttons.forEach { $0.isEnabled = enabled }
    }

    @objc private func homeTapped() { onAndroidKey?(AndroidKey.home) }
    @objc private func recentsTapped() { onAndroidKey?(AndroidKey.recents) }

    private static func makeButton(symbol: String, label: String) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .texturedRounded
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityRole(.button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        return button
    }
}

@MainActor
final class MirrorTitlebarInteractionView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var titlebarVisible = false
    var customBehaviorEnabled = true

    private var titlebarTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let titlebarTrackingArea {
            removeTrackingArea(titlebarTrackingArea)
            self.titlebarTrackingArea = nil
        }
        let height = min(32, bounds.height)
        guard height > 0, bounds.width > 0 else { return }
        let area = NSTrackingArea(
            rect: NSRect(x: bounds.minX, y: bounds.maxY - height,
                         width: bounds.width, height: height),
            options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        titlebarTrackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard customBehaviorEnabled, titlebarVisible else { return nil }
        let localPoint = convert(point, from: superview)
        guard localPoint.y >= bounds.maxY - 32 else { return nil }
        return super.hitTest(point)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowDidResignKey() { onHoverChanged?(false) }
}
