import MirageCore

extension AppModel {
    func startGamepadMonitoring() {
        guard gamepadMonitor == nil else { return }
        let monitor = GamepadMonitor()
        monitor.onSnapshot = { [weak self] snapshot in
            self?.receiveGamepad(snapshot)
        }
        monitor.onTick = { [weak self] dt in
            self?.keymap?.tickGamepad(dt: dt)
        }
        monitor.onConnectionChange = { [weak self] name in
            self?.gamepadConnectionName = name
            self?.menuBar?.updateGamepad(name: name)
        }
        gamepadMonitor = monitor
        monitor.start()
    }

    func receiveGamepad(_ snapshot: GamepadSnapshot) {
        keymap?.handleGamepadSnapshot(snapshot)
    }

    func configureGamepadCapture() {
        keymap?.onAndroidKey = { [weak self] key in
            guard let self else { return }
            self.sendAndroidKey(key)
        }
        keymap?.onCaptureKeyboardKey = { [weak self] key in
            guard let self, self.editorSession?.rebindingID != nil else { return false }
            if key == .key("GoBack") {
                self.editorSession = self.editorSession?.cancelRebinding()
            } else {
                self.editorSession = self.editorSession?.capturingKeyboardKey(key)
                self.applyCapturedEditorSession()
            }
            return true
        }
        keymap?.onCaptureGamepadButton = { [weak self] button in
            guard let self, self.editorSession?.rebindingID != nil else { return false }
            self.editorSession = self.editorSession?.capturingGamepadButton(button)
            self.applyCapturedEditorSession()
            return true
        }
    }

    private func applyCapturedEditorSession() {
        guard let session = editorSession else { return }
        let updatedProfile = session.profile()
        profile = updatedProfile
        keymap?.reload(updatedProfile)
    }
}
