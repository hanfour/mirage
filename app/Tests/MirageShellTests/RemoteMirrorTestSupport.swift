import Foundation
import MirageCore
@testable import MirageShell

/// 假編碼器：每次 `encode` 同步吐一個存取單元；第一幀或被要求時是 keyframe。
final class RemoteMirrorFakeEncoder: RemoteFrameEncoding, @unchecked Sendable {
    static let sps = Data([0x27, 0x42, 0x00, 0x32, 0xab, 0x40, 0x22, 0x00, 0x96, 0xf2, 0xe8])
    static let pps = Data([0x28, 0xce, 0x3c, 0x80])
    private let lock = NSLock()
    private let failEncoding: Bool
    private var forceKeyframe = true
    let encoded = CountGate()
    private var starts: [ContinuousClock.Instant] = []
    private var timestamps: [ContinuousClock.Instant] = []
    private(set) var encodeCalls = 0
    private(set) var keyframeRequests = 0
    private(set) var invalidated = false

    init(failEncoding: Bool = false) {
        self.failEncoding = failEncoding
    }

    func encode(_ frame: Frame, onAccessUnit: @escaping @Sendable (H264AccessUnit) -> Void) throws {
        if failEncoding { throw RemoteMirrorTestFailure.encoding }
        lock.lock()
        encodeCalls += 1
        starts.append(.now)
        timestamps.append(frame.receivedAt)
        let key = forceKeyframe
        forceKeyframe = false
        lock.unlock()
        let slice = Data([key ? 0x65 : 0x41, UInt8(truncatingIfNeeded: frame.width)])
        encoded.increment()
        onAccessUnit(H264AccessUnit(nals: key ? [Self.sps, Self.pps, slice] : [slice], isKeyframe: key))
    }

    func requestKeyframe() { lock.lock(); keyframeRequests += 1; forceKeyframe = true; lock.unlock() }
    func invalidate() { lock.lock(); invalidated = true; lock.unlock() }
    var encodingStarts: [ContinuousClock.Instant] { lock.lock(); defer { lock.unlock() }; return starts }
    var presentationTimes: [ContinuousClock.Instant] { lock.lock(); defer { lock.unlock() }; return timestamps }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return encodeCalls }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return keyframeRequests }
    var wasInvalidated: Bool { lock.lock(); defer { lock.unlock() }; return invalidated }
}

/// 記錄 `InputQueue` 送出的觸控；證明遠端觸控走的是 `inputQueue.touches`，不是別條路。
final class RemoteMirrorRecordingInjector: InputInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[TouchSpec]] = []
    let gate = CountGate()
    func sendTouches(_ touches: [TouchSpec]) async { record(touches) }
    private func record(_ touches: [TouchSpec]) { lock.lock(); stored.append(touches); lock.unlock(); gate.increment() }
    private var storedKeys: [(KeyCode, Bool)] = []
    let keyGate = CountGate()
    func sendKey(_ code: KeyCode, down: Bool) async { recordKey(code, down: down) }
    private func recordKey(_ code: KeyCode, down: Bool) {
        lock.lock(); storedKeys.append((code, down)); lock.unlock(); keyGate.increment()
    }
    var keys: [(KeyCode, Bool)] { lock.lock(); defer { lock.unlock() }; return storedKeys }
    func sendTap(nx: Double, ny: Double, down: Bool) async {}
    var touches: [[TouchSpec]] { lock.lock(); defer { lock.unlock() }; return stored }
}

enum RemoteMirrorTestFailure: Error { case unexpectedMessageKind, encoding }

