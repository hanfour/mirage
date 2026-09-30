import MirageCore

extension AppModel {
    func setupGuestActions() {
        menuBar?.onAndroidKey = { [weak self] key in self?.sendAndroidKey(key) }
        menuBar?.onTakeScreenshot = { [weak self] in
            Task { @MainActor in await self?.takeScreenshot() }
        }
    }

    func sendAndroidKey(_ w3c: String) {
        inputQueue.key(.key(w3c), down: true)
        inputQueue.key(.key(w3c), down: false)
    }
}
