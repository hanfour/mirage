import AppKit
import CoreGraphics
import Darwin
import Foundation

private final class TestControlResponseBox: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    var response: Data?
}

@MainActor
final class TestControlChannel {
    private weak var model: AppModel?
    private let path: String
    private var serverDescriptor: Int32?

    init(model: AppModel, path: String) {
        self.model = model
        self.path = path
    }

    func start() {
        guard serverDescriptor == nil else { return }
        do {
            let descriptor = try TestControlSocket.open(path: path)
            serverDescriptor = descriptor
            NSLog("[test-control] 已開啟：%@", path)

            let handler: @Sendable (Data) -> Data = { [weak self] line in
                guard let self else {
                    return TestControlProtocol.failureResponse("Mirage 已結束")
                }
                let box = TestControlResponseBox()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else {
                            box.response = TestControlProtocol.failureResponse("Mirage 已結束")
                            box.semaphore.signal()
                            return
                        }
                        Task { @MainActor in
                            box.response = await self.handle(line)
                            box.semaphore.signal()
                        }
                    }
                }
                box.semaphore.wait()
                return box.response ?? TestControlProtocol.failureResponse("控制命令沒有回應")
            }
            DispatchQueue.global(qos: .userInitiated).async {
                TestControlSocket.serve(descriptor: descriptor, handler: handler)
            }
        } catch {
            NSLog("[test-control] 無法開啟 %@：%@", path, error.localizedDescription)
        }
    }

    func stop() {
        guard let descriptor = serverDescriptor else { return }
        serverDescriptor = nil
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        TestControlSocket.removeSocket(at: path)
    }

    private func handle(_ line: Data) async -> Data {
        do {
            let command = try TestControlProtocol.decode(line)
            let fields = try await execute(command)
            return TestControlProtocol.successResponse(fields)
        } catch {
            return TestControlProtocol.failureResponse(for: error)
        }
    }

    private func execute(_ command: TestControlCommand) async throws -> [String: Any] {
        guard let model else {
            throw TestControlProtocolError.invalid("Mirage 狀態已結束")
        }
        switch command {
        case .state:
            return try state(for: model)
        case .mouse(let action, let point, let unit):
            switch action {
            case .click:
                try postMouse(.down, point: point, unit: unit)
                do {
                    try postMouse(.up, point: point, unit: unit)
                } catch {
                    try? postMouse(.up, point: point, unit: unit)
                    throw error
                }
            case .down, .drag, .up:
                try postMouse(action, point: point, unit: unit)
            }
        case .drag(let from, let to, let steps, let interval, let unit):
            _ = try resolvedPoint(from, unit: unit)
            _ = try resolvedPoint(to, unit: unit)
            try postMouse(.down, point: from, unit: unit)
            do {
                for index in 1...steps {
                    await pause(milliseconds: interval)
                    let fraction = Double(index) / Double(steps)
                    let point = TestControlPoint(x: from.x + (to.x - from.x) * fraction,
                                                 y: from.y + (to.y - from.y) * fraction)
                    try postMouse(.drag, point: point, unit: unit)
                }
                await pause(milliseconds: interval)
                try postMouse(.up, point: to, unit: unit)
            } catch {
                try? postMouse(.up, point: to, unit: unit)
                throw error
            }
        case .scroll(let point, let dx, let dy, let steps, let interval, let momentum, let unit):
            _ = try resolvedPoint(point, unit: unit)
            try postScroll(point: point, dx: 0, dy: 0, phase: .began, unit: unit)
            do {
                for _ in 0..<steps {
                    await pause(milliseconds: interval)
                    try postScroll(point: point, dx: dx, dy: dy, phase: .changed, unit: unit)
                }
                await pause(milliseconds: interval)
                try postScroll(point: point, dx: 0, dy: 0, phase: .ended, unit: unit)
            } catch {
                try? postScroll(point: point, dx: 0, dy: 0, phase: .ended, unit: unit)
                throw error
            }
            if momentum > 0 {
                for index in 0..<momentum {
                    await pause(milliseconds: interval)
                    let phase: TestControlScrollPhase = index == momentum - 1 ? .momentumEnded : .momentumChanged
                    try postScroll(point: point, dx: dx, dy: dy, phase: phase, unit: unit)
                }
            }
        case .key(let keyCode, let modifiers, let action):
            switch action {
            case .press:
                try postKey(keyCode: keyCode, modifiers: modifiers, down: true)
                try postKey(keyCode: keyCode, modifiers: modifiers, down: false)
            case .down:
                try postKey(keyCode: keyCode, modifiers: modifiers, down: true)
            case .up:
                try postKey(keyCode: keyCode, modifiers: modifiers, down: false)
            }
        case .gamepad(let snapshot):
            model.gamepadMonitor?.setTestOverride(active: snapshot != .neutral)
            model.receiveGamepad(snapshot)
        case .titlebar(let visible):
            model.windowController.setTitlebarVisibleForTest(visible)
        case .fullscreen(let on):
            guard await model.windowController.setFullScreenForTest(on) else {
                throw TestControlProtocolError.invalid("全螢幕切換逾時")
            }
        }
        return [:]
    }

    private func state(for model: AppModel) throws -> [String: Any] {
        let window = model.windowController.window()
        guard let contentView = window.contentView else {
            throw TestControlProtocolError.invalid("鏡像視窗沒有內容區")
        }
        guard let actions = model.windowController.titlebarActions,
              actions.buttons.count == 2 else {
            throw TestControlProtocolError.invalid("標題列按鈕尚未建立")
        }
        let buttons: [String: Any] = [
            "home": try frame(of: actions.buttons[0], in: contentView),
            "recents": try frame(of: actions.buttons[1], in: contentView),
        ]
        let windowFrame = window.frame
        let contentSize = contentView.bounds.size
        return [
            "pid": Int(getpid()),
            "windowNumber": window.windowNumber,
            "windowFrame": ["x": windowFrame.origin.x, "y": windowFrame.origin.y,
                            "width": windowFrame.width, "height": windowFrame.height],
            "contentSize": ["width": contentSize.width, "height": contentSize.height],
            "fullscreen": window.styleMask.contains(.fullScreen),
            "titlebarVisible": model.windowController.isTitlebarVisible,
            "connected": model.connState == .connected,
            "connection": AppModel.label(model.connState),
            "buttons": buttons,
            "profile": model.profile?.gameId ?? NSNull(),
            "keymapHasProfile": model.keymap?.hasProfile ?? false,
            "textMode": model.keymap?.isTextMode ?? false,
        ]
    }

    private func frame(of view: NSView, in contentView: NSView) throws -> [String: CGFloat] {
        let rect = view.convert(view.bounds, to: contentView)
        guard rect.width > 0, rect.height > 0 else {
            throw TestControlProtocolError.invalid("標題列按鈕 frame 無效")
        }
        return ["x": rect.minX - contentView.bounds.minX,
                "y": contentView.bounds.maxY - rect.maxY,
                "width": rect.width, "height": rect.height]
    }

    private func resolvedPoint(_ point: TestControlPoint, unit: TestControlUnit) throws -> TestControlPoint {
        guard let contentView = model?.windowController.window().contentView else {
            throw TestControlProtocolError.invalid("鏡像視窗尚未建立")
        }
        return try TestControlProtocol.point(point, unit: unit,
                                            width: Double(contentView.bounds.width),
                                            height: Double(contentView.bounds.height))
    }

    private func postMouse(_ action: TestControlMouseAction, point: TestControlPoint,
                           unit: TestControlUnit) throws {
        let window = model?.windowController.window()
        guard let window, let contentView = window.contentView else {
            throw TestControlProtocolError.invalid("鏡像視窗尚未建立")
        }
        let size = contentView.bounds.size
        let resolved = try TestControlProtocol.point(point, unit: unit,
                                                    width: Double(size.width), height: Double(size.height))
        let localPoint = CGPoint(x: contentView.bounds.minX + resolved.x,
                                 y: contentView.bounds.maxY - resolved.y)
        let location = contentView.convert(localPoint, to: nil)
        let type: NSEvent.EventType
        switch action {
        case .down: type = .leftMouseDown
        case .drag: type = .leftMouseDragged
        case .up: type = .leftMouseUp
        case .click: type = .leftMouseDown
        }
        guard let event = NSEvent.mouseEvent(with: type, location: location,
                                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: action == .up ? 0 : 1) else {
            throw TestControlProtocolError.invalid("無法建立滑鼠事件")
        }
        NSApp.postEvent(event, atStart: false)
    }

    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    /// CoreGraphics 未公開的函式，只在測試控制通道使用。找不到時捲動指令回錯誤。
    private static let setWindowLocation: SetWindowLocation? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetWindowLocation.self)
    }()

    private func postScroll(point: TestControlPoint, dx: Double, dy: Double,
                            phase: TestControlScrollPhase, unit: TestControlUnit) throws {
        guard let window = model?.windowController.window(), let contentView = window.contentView else {
            throw TestControlProtocolError.invalid("鏡像視窗尚未建立")
        }
        let size = contentView.bounds.size
        let resolved = try TestControlProtocol.point(point, unit: unit,
                                                    width: Double(size.width), height: Double(size.height))
        let localPoint = CGPoint(x: contentView.bounds.minX + resolved.x,
                                 y: contentView.bounds.maxY - resolved.y)
        let windowPoint = contentView.convert(localPoint, to: nil)
        let cocoaScreenPoint = window.convertPoint(toScreen: windowPoint)
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY ?? cocoaScreenPoint.y
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else {
            throw TestControlProtocolError.invalid("無法建立捲動 CGEvent")
        }
        event.location = CGPoint(x: cocoaScreenPoint.x, y: primaryScreenTop - cocoaScreenPoint.y)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Quartz 目前以欄位 99 與 123 表示捲動 phase 和 momentum phase。
        event.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(scrollPhaseValue(phase)))
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: Int64(momentumPhaseValue(phase)))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                   value: Int64(window.windowNumber))
        // 欄位 51 未公開，但 NSEvent(cgEvent:) 的 windowNumber 只看它（91／92 不影響）。2026-10-01 在
        // macOS 26 逐一試 0 到 200 號欄位確認。下方仍檢查轉換結果，系統改版失效時會回錯誤而不是送錯事件。
        event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
        // 設了欄位 51 之後，NSEvent 的 locationInWindow 不再由 event.location 換算，而是讀
        // CGEventSetWindowLocation 設的視窗座標（原點在視窗左上），沒設時固定落在視窗左下角。
        guard let setWindowLocation = Self.setWindowLocation else {
            throw TestControlProtocolError.invalid("找不到 CGEventSetWindowLocation，無法指定捲動位置")
        }
        setWindowLocation(event, CGPoint(x: windowPoint.x, y: window.frame.height - windowPoint.y))
        guard let converted = NSEvent(cgEvent: event) else {
            throw TestControlProtocolError.invalid("CGEvent 無法轉成 NSEvent")
        }
        let expectedPhase = eventPhase(phase)
        guard converted.windowNumber == window.windowNumber else {
            throw TestControlProtocolError.invalid("捲動事件 windowNumber 不符，實際為 \(converted.windowNumber)")
        }
        guard abs(converted.locationInWindow.x - windowPoint.x) < 0.5,
              abs(converted.locationInWindow.y - windowPoint.y) < 0.5 else {
            throw TestControlProtocolError.invalid("捲動事件位置不符，實際為 \(converted.locationInWindow)，期待 \(windowPoint)")
        }
        guard converted.phase == expectedPhase else {
            throw TestControlProtocolError.invalid("捲動事件 phase 不符，實際為 \(converted.phase.rawValue)")
        }
        guard converted.momentumPhase == momentumEventPhase(phase) else {
            throw TestControlProtocolError.invalid("捲動事件 momentum phase 不符")
        }
        guard converted.hasPreciseScrollingDeltas else {
            throw TestControlProtocolError.invalid("捲動事件沒有精確捲動 delta")
        }
        NSApp.postEvent(converted, atStart: false)
    }

    private func postKey(keyCode: UInt16, modifiers: [String], down: Bool) throws {
        guard let window = model?.windowController.window(), let contentView = window.contentView else {
            throw TestControlProtocolError.invalid("鏡像視窗尚未建立")
        }
        // 不依賴 NSApp.keyWindow；背景 app 可能沒有 key window，指定 responder 不會啟用 app。
        if let mirrorView = firstMirrorView(in: contentView) {
            window.makeFirstResponder(mirrorView)
        }
        let contentCenter = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        let location = contentView.convert(contentCenter, to: nil)
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains("cmd") { flags.insert(.command) }
        if modifiers.contains("shift") { flags.insert(.shift) }
        if modifiers.contains("option") { flags.insert(.option) }
        if modifiers.contains("control") { flags.insert(.control) }
        let charactersIgnoringModifiers = Self.keyCharacters[keyCode] ?? ""
        let characters = flags.contains(.shift) ? charactersIgnoringModifiers.uppercased() : charactersIgnoringModifiers
        let type: NSEvent.EventType = down ? .keyDown : .keyUp
        guard let event = NSEvent.keyEvent(with: type, location: location, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters,
                                           charactersIgnoringModifiers: charactersIgnoringModifiers,
                                           isARepeat: false, keyCode: keyCode) else {
            throw TestControlProtocolError.invalid("無法建立鍵盤事件")
        }
        NSApp.postEvent(event, atStart: false)
    }

    private func firstMirrorView(in view: NSView) -> MirrorMTKView? {
        if let mirrorView = view as? MirrorMTKView { return mirrorView }
        for subview in view.subviews {
            if let mirrorView = firstMirrorView(in: subview) { return mirrorView }
        }
        return nil
    }

    private func pause(milliseconds: Int) async {
        guard milliseconds > 0 else { return }
        try? await Task.sleep(for: .milliseconds(Int64(milliseconds)))
    }

    /// CGEvent 欄位 99 用 CGScrollPhase 的數值（began 1、changed 2、ended 4），不是 NSEvent.Phase
    /// （began 1、changed 4、ended 8）。用錯會讓 changed 被轉成 ended。
    private func scrollPhaseValue(_ phase: TestControlScrollPhase) -> UInt64 {
        switch phase {
        case .began: return UInt64(CGScrollPhase.began.rawValue)
        case .changed: return UInt64(CGScrollPhase.changed.rawValue)
        case .ended: return UInt64(CGScrollPhase.ended.rawValue)
        case .momentumChanged, .momentumEnded: return 0
        }
    }

    /// 欄位 123 用 CGMomentumScrollPhase（begin 1、continue 2、end 3）。
    private func momentumPhaseValue(_ phase: TestControlScrollPhase) -> UInt64 {
        switch phase {
        case .momentumChanged: return UInt64(CGMomentumScrollPhase.continuous.rawValue)
        case .momentumEnded: return UInt64(CGMomentumScrollPhase.end.rawValue)
        case .began, .changed, .ended: return 0
        }
    }

    private func eventPhase(_ phase: TestControlScrollPhase) -> NSEvent.Phase {
        switch phase {
        case .began: return .began
        case .changed: return .changed
        case .ended: return .ended
        case .momentumChanged, .momentumEnded: return []
        }
    }

    private func momentumEventPhase(_ phase: TestControlScrollPhase) -> NSEvent.Phase {
        switch phase {
        case .momentumChanged: return .changed
        case .momentumEnded: return .ended
        case .began, .changed, .ended: return []
        }
    }

    private static let keyCharacters: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 36: "\r",
        37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "n", 46: "m", 47: ".", 48: "\t", 49: " ", 50: "`",
        51: "\u{8}", 53: "\u{1B}", 123: "\u{F702}", 124: "\u{F703}",
        125: "\u{F701}", 126: "\u{F700}",
    ]
}

private enum TestControlSocket {
    static func open(path: String) throws -> Int32 {
        var existing = stat()
        let statResult = path.withCString { lstat($0, &existing) }
        if statResult == 0 {
            guard existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
                throw TestControlProtocolError.invalid("socket 路徑已存在且不是 socket")
            }
            guard path.withCString({ unlink($0) }) == 0 else {
                throw TestControlProtocolError.invalid("無法刪除殘留 socket：\(String(cString: strerror(errno)))")
            }
        } else if errno != ENOENT {
            throw TestControlProtocolError.invalid("無法檢查 socket 路徑：\(String(cString: strerror(errno)))")
        }

        var address = sockaddr_un()
        let pathBytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw TestControlProtocolError.invalid("socket 路徑太長")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                pathBytes.withUnsafeBufferPointer { source in
                    _ = memcpy(destination, source.baseAddress!, pathBytes.count)
                }
            }
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw TestControlProtocolError.invalid("無法建立 Unix socket：\(String(cString: strerror(errno)))")
        }
        let bindResult: Int32
        do {
            let oldMask = umask(0o177)
            defer { _ = umask(oldMask) }
            bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw TestControlProtocolError.invalid("無法綁定 Unix socket：\(message)")
        }
        guard path.withCString({ chmod($0, mode_t(0o600)) }) == 0,
              Darwin.listen(descriptor, SOMAXCONN) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(descriptor)
            removeSocket(at: path)
            throw TestControlProtocolError.invalid("無法設定 Unix socket 權限或監聽：\(message)")
        }
        return descriptor
    }

    static func removeSocket(at path: String) {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { return }
        _ = path.withCString { unlink($0) }
    }

    static func serve(descriptor: Int32, handler: @escaping @Sendable (Data) -> Data) {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                           socklen_t(MemoryLayout<Int32>.size))
            serveClient(client, handler: handler)
            Darwin.close(client)
        }
    }

    private static func serveClient(_ descriptor: Int32,
                                    handler: @escaping @Sendable (Data) -> Data) {
        var pending = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBufferPointer { buffer in
                Darwin.read(descriptor, buffer.baseAddress!, buffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(contentsOf: bytes.prefix(count))
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                let nextLine = pending.index(after: newline)
                pending.removeSubrange(pending.startIndex..<nextLine)
                guard line.count <= 65_536 else { return }
                guard writeAll(handler(line), to: descriptor) else { return }
            }
            if pending.count > 65_536 { return }
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(descriptor, baseAddress.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if count == 0 { return false }
                offset += count
            }
            return true
        }
    }
}
