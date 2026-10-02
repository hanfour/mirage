import Foundation
import MirageCore

/// server 回呼共用的執行緒安全狀態轉接器。
final class RemoteControllerRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: RemoteMirrorController?
    private var displayRotation = 0

    func attach(_ controller: RemoteMirrorController) { lock.lock(); target = controller; lock.unlock() }

    func record(_ stats: RemoteClientStats?) {
        lock.lock(); let controller = target; lock.unlock()
        controller?.recordClientStats(stats)
    }

    func request() {
        lock.lock(); let controller = target; lock.unlock()
        controller?.requestKeyframe()
    }

    func setDisplayRotation(_ rotation: Int) {
        guard (0...3).contains(rotation) else { return }
        lock.lock(); displayRotation = rotation; lock.unlock()
    }

    func upright(_ touches: [TouchSpec]) -> [TouchSpec] {
        lock.lock(); let rotation = displayRotation; lock.unlock()
        return touches.map {
            TouchSpec(identifier: $0.identifier,
                      point: DisplayRotation.uprightPoint(fromPanel: $0.point, rotation: rotation),
                      down: $0.down, isRemoteMove: $0.isRemoteMove)
        }
    }
}
