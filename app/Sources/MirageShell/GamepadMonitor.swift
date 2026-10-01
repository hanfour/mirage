import AppKit
import GameController
import MirageCore

/// GameController 的薄層：將目前控制器值轉成 Core 快照，並提供 60 Hz 的注入 dt。
@MainActor
final class GamepadMonitor {
    private var controller: GCController?
    private var timer: Timer?
    private var lastTick: TimeInterval?
    private var foreground = false
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    var onSnapshot: (@MainActor (GamepadSnapshot) -> Void)?
    var onTick: (@MainActor (Double) -> Void)?
    var onConnectionChange: (@MainActor (String?) -> Void)?

    func start() {
        guard observers.isEmpty else { return }
        GCController.shouldMonitorBackgroundEvents = false
        for name in [Notification.Name.GCControllerDidConnect,
                     Notification.Name.GCControllerDidDisconnect,
                     Notification.Name.GCControllerDidBecomeCurrent] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshController() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setForeground(true) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setForeground(false) }
        })
        refreshController()
        let isActive = (NSApp as NSApplication?)?.isActive ?? false
        setForeground(isActive)
    }

    func resynchronize() {
        guard foreground, let controller else { return }
        onSnapshot?(Self.snapshot(from: controller))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = nil
        onSnapshot?(.neutral)
        onConnectionChange?(nil)
    }

    private func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if active {
            refreshController()
            startTimer()
        } else {
            timer?.invalidate()
            timer = nil
            lastTick = nil
            onSnapshot?(.neutral)
        }
    }

    private func refreshController() {
        let available = GCController.controllers()
        let current = GCController.current
        let currentIsConnected = current.map { candidate in available.contains { $0 === candidate } } ?? false
        let selected = currentIsConnected ? current : available.last
        guard selected !== controller else {
            if foreground { resynchronize() }
            return
        }
        controller?.extendedGamepad?.valueChangedHandler = nil
        onSnapshot?(.neutral)
        controller = selected
        onConnectionChange?(selected.map { $0.vendorName ?? "未命名手把" })
        guard let selected, let gamepad = selected.extendedGamepad else { return }
        gamepad.valueChangedHandler = { [weak self, weak selected] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let selected, self.foreground,
                          selected === self.controller else { return }
                    self.onSnapshot?(Self.snapshot(from: selected))
                }
            }
        }
        if foreground { resynchronize() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let next = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.foreground else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let dt = max(0, now - (self.lastTick ?? now))
                self.lastTick = now
                self.onTick?(dt)
            }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    private static func snapshot(from controller: GCController) -> GamepadSnapshot {
        guard let gamepad = controller.extendedGamepad else { return .neutral }
        var buttons: Set<GamepadButton> = []
        let discrete: [(GamepadButton, GCControllerButtonInput)] = [
            (.a, gamepad.buttonA), (.b, gamepad.buttonB), (.x, gamepad.buttonX), (.y, gamepad.buttonY),
            (.leftShoulder, gamepad.leftShoulder), (.rightShoulder, gamepad.rightShoulder),
            (.dpadUp, gamepad.dpad.up), (.dpadDown, gamepad.dpad.down),
            (.dpadLeft, gamepad.dpad.left), (.dpadRight, gamepad.dpad.right),
        ]
        for (button, input) in discrete where input.isPressed { buttons.insert(button) }
        if gamepad.leftThumbstickButton?.isPressed == true { buttons.insert(.leftThumbstickButton) }
        if gamepad.rightThumbstickButton?.isPressed == true { buttons.insert(.rightThumbstickButton) }
        if gamepad.buttonMenu?.isPressed == true { buttons.insert(.menu) }
        if gamepad.buttonOptions?.isPressed == true { buttons.insert(.options) }

        return GamepadSnapshot(
            buttons: buttons,
            leftStick: GamepadVector(x: Double(gamepad.leftThumbstick.xAxis.value),
                                     y: Double(gamepad.leftThumbstick.yAxis.value)),
            rightStick: GamepadVector(x: Double(gamepad.rightThumbstick.xAxis.value),
                                      y: Double(gamepad.rightThumbstick.yAxis.value)),
            leftTrigger: Double(gamepad.leftTrigger.value),
            rightTrigger: Double(gamepad.rightTrigger.value))
    }
}
