import MirageCore

extension AppModel {
    func sendAndroidKey(_ w3c: String) {
        inputQueue.key(.key(w3c), down: true)
        inputQueue.key(.key(w3c), down: false)
    }
}
