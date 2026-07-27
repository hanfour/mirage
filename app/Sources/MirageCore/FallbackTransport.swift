import Foundation

/// 組合器：primary 判定不可用時無縫換到 secondary。本身不碰 gRPC。
///
/// **只對 `TransportError.mmapUnusable` 降級。** primary 若因模擬器被殺而丟
/// `.unavailable`，那是斷線，必須照常往上傳播交給既有重連迴圈處理——絕不能被誤判成
/// 「MMAP 壞了」而永久降級，否則使用者斷線一次就永遠回不到 MMAP，而那種退化不會有人
/// 回報，只會默默吃掉整個優化。
///
/// **決定的有效範圍是一個 instance = 一條 channel**：`EmulatorClient.dropChannel()` 會重建
/// transport，決定隨之消失，重連後重新探測。自癒，且符合「模擬器可能在重連之間被換掉」。
public final class FallbackTransport: DisplayTransport, @unchecked Sendable {
    private let primary: DisplayTransport
    private let secondary: DisplayTransport
    private let lock = NSLock()
    private var fellBack = false

    public init(primary: DisplayTransport, secondary: DisplayTransport) {
        self.primary = primary
        self.secondary = secondary
    }

    private var hasFallenBack: Bool {
        lock.lock(); defer { lock.unlock() }; return fellBack
    }

    private func markFallenBack() {
        lock.lock(); fellBack = true; lock.unlock()
    }

    public func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        if hasFallenBack { return secondary.frames(width: width, height: height) }
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await frame in self.primary.frames(width: width, height: height) {
                        if Task.isCancelled { return }
                        cont.yield(frame)
                    }
                    cont.finish()                       // primary 正常結束，不降級
                } catch let err as TransportError {
                    guard case .mmapUnusable = err else {
                        cont.finish(throwing: err)      // 斷線等其他錯誤照常傳播
                        return
                    }
                    self.markFallenBack()
                    await self.drainSecondary(into: cont, width: width, height: height)
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// 降級後把 secondary 的幀灌進**同一條** continuation——消費端看到的是一條不中斷的串流。
    private func drainSecondary(into cont: AsyncThrowingStream<Frame, Error>.Continuation,
                                width: Int, height: Int) async {
        do {
            for try await frame in secondary.frames(width: width, height: height) {
                if Task.isCancelled { return }
                cont.yield(frame)
            }
            cont.finish()
        } catch {
            cont.finish(throwing: error)
        }
    }
}
