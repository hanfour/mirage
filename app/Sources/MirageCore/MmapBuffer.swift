import Darwin
import Foundation

/// 一塊由 emulator 寫入、由我們唯讀映射的共享緩衝區。
///
/// `@unchecked Sendable`：內部持有裸指標與 fd，以 `NSLock` 保護（比照既有
/// `GrpcChannelBox`／`GrpcAudioTransport` 的慣例）。不使用 `nonisolated(unsafe)`。
public final class MmapBuffer: @unchecked Sendable {
    public let path: String
    private let byteCount: Int
    private let lock = NSLock()
    private var fd: Int32
    private var base: UnsafeMutableRawPointer?

    /// 建檔（截成指定大小）→ 唯讀映射。任一步失敗回 nil，呼叫端據此降級，不崩。
    public init?(path: String, byteCount: Int) {
        guard byteCount > 0 else { return nil }
        let opened = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard opened >= 0 else { return nil }
        guard ftruncate(opened, off_t(byteCount)) == 0 else {
            Darwin.close(opened); unlink(path); return nil
        }
        guard let mapped = mmap(nil, byteCount, PROT_READ, MAP_SHARED, opened, 0),
              mapped != MAP_FAILED else {
            Darwin.close(opened); unlink(path); return nil
        }
        self.path = path
        self.byteCount = byteCount
        self.fd = opened
        self.base = mapped
    }

    deinit { close() }

    /// 把當前映射內容**複製**出來。
    ///
    /// **複製是正確性所必需，不是可以優化掉的浪費**：emulator 會原地覆寫這塊區域來寫
    /// 下一幀，而 `LatestFrameBox` 持有最新幀、`Renderer` 要到 vsync 才讀。若回傳指向
    /// 映射區的 view（`Data(bytesNoCopy:)`），渲染器會讀到正在被覆寫的記憶體 → 撕裂畫面。
    /// 已量化：複製只值 0.2 ms/幀（見 spec §1.1），拿它換正確性極為划算。
    public func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let base else { return Data() }
        return Data(bytes: base, count: byteCount)
    }

    /// `munmap` + `close(fd)` + `unlink`。冪等——重複呼叫不得崩潰。
    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let base {
            munmap(base, byteCount)
            self.base = nil
        }
        if fd >= 0 {
            Darwin.close(fd)
            unlink(path)          // 不檢查回傳值：檔案殘留可容忍，中斷流程不可
            fd = -1
        }
    }
}
