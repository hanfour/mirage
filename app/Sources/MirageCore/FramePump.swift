import Foundation

/// 串流消費生命週期：attach 換源時自動取消舊消費 task。
public actor FramePump {
    private var task: Task<Void, Never>?

    public init() {}

    public func attach(_ stream: AsyncThrowingStream<Frame, Error>,
                       into box: LatestFrameBox,
                       onEnd: @escaping @Sendable (Error?) -> Void) {
        task?.cancel()
        task = Task {
            do {
                for try await frame in stream {
                    if Task.isCancelled { return }
                    box.put(frame)
                }
                onEnd(nil)
            } catch {
                if !Task.isCancelled { onEnd(error) }
            }
        }
    }

    public func detach() {
        task?.cancel()
        task = nil
    }
}
