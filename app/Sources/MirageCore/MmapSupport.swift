import Foundation

/// MMAP 傳輸的純函式支援：路徑產生、handle 組裝、全零判定。
/// 全部無副作用、無 I/O，故可完整單元測試。
public enum MmapSupport {
    /// RGBA8888 的緩衝區位元組數。任一維度 <= 0 → 0（呼叫端據此拒絕掛載）。
    public static func byteCount(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        return width * height * 4
    }

    /// 每次掛載都用**唯一**路徑。
    ///
    /// 理由（上游 b/537802959）：伺服器端的 pre-borrow 會依 handle 快取共享記憶體區塊，
    /// 而該 bug 正是「用 0 大小 borrow 並毒化 cache」。換新路徑就沒有任何殘留狀態的疑慮，
    /// 同時避免舊檔殘留，多開時也天然不衝突。
    public static func handlePath(tempDir: String, pid: Int32, seq: Int,
                                  width: Int, height: Int) -> String {
        let base = tempDir.hasSuffix("/") ? String(tempDir.dropLast()) : tempDir
        return "\(base)/mirage_mmap_\(pid)_\(seq)_\(width)x\(height).bin"
    }

    /// proto 的 `ImageTransport.handle` 需要 `file://` scheme。
    public static func handleURL(path: String) -> String { "file://\(path)" }

    /// 全零判定——降級決策的依據（前 3 幀皆 blank 即判定 MMAP 不可用）。
    ///
    /// **完整掃描，不取樣**：一次 7.2 MB、最多做 3 次，是一次性成本，換取判定不會因
    /// 取樣點恰好落在畫面的黑色區域而誤判。判定完成後這條檢查不再執行，穩態零開銷。
    public static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0 }
    }
}

/// MMAP 探測狀態機：前 `frameBudget` 幀若皆全零則判定不可用。純邏輯、不碰 gRPC，故可完整
/// 單元測試（`MmapStreamTransport` 沒有單元測試網——正是這個狀態機被抽出來的理由）。
///
/// 涵蓋兩個事件：
/// - `observe(isBlank:)`：探測期間逐幀呼叫。
/// - `endedWithoutContent()`：底層串流**自然結束**時呼叫一次。
///
/// 第二個事件補的是一個真實漏洞：若 RPC 在探測窗口跑完之前就自然結束（伺服器只送了
/// 少於 `frameBudget` 個全零通知就收攤），單靠 `observe` 永遠不會走到「已看滿 frameBudget
/// 幀」那個判定分支，呼叫端會誤以為這是乾淨結束。而 `FallbackTransport` 把乾淨結束視為
/// 「primary 正常，不降級」——兩者疊加，一條真的壞掉的 MMAP 路徑只要提早收攤 RPC，就會
/// 落得「無畫面、無降級、無恢復路徑」，比設計刻意偏向的「寧可誤降級」更糟。
public struct MmapBlankProbe {
    public enum Decision: Equatable {
        case stillProbing   // 探測中且本幀全零——不得 yield（避免黑畫面閃爍）
        case deliver        // 送出這一幀
        case unusable       // 判定不可用——呼叫端應丟 .mmapUnusable
    }

    private let frameBudget: Int
    private var seen = 0
    private var sawContent = false

    public init(frameBudget: Int = 3) {
        self.frameBudget = frameBudget
    }

    /// 每收到一幀呼叫一次。判定完成（`sawContent`）後不再檢查——穩態零開銷。
    public mutating func observe(isBlank: Bool) -> Decision {
        if sawContent { return .deliver }
        guard isBlank else {
            sawContent = true
            return .deliver
        }
        seen += 1
        return seen >= frameBudget ? .unusable : .stillProbing
    }

    /// 底層串流自然結束時呼叫一次。`true` 代表探測完成前從未看到內容——呼叫端應把這視同
    /// `.unusable`（丟 `.mmapUnusable`），不能放行成乾淨結束。
    public func endedWithoutContent() -> Bool {
        !sawContent
    }
}

/// MMAP 版本安全閘：穩定版 emulator（36.x）收到 MMAP 請求會 SIGSEGV
/// （phase0/RESULTS-0b.md，2/2 確定性重現），主版號 ≥37 才允許。解析失敗一律拒絕。
///
/// 上游根因（b/537802959）揭露 36.x 的崩潰**可能**也只是同一個 0×0 pre-borrow、送明確
/// 尺寸就不會炸——但我們沒有證據，而驗證代價是故意炸掉一台使用者的 VM。維持 ≥37。
public enum MmapVersionGate {
    public static func allows(versionString: String) -> Bool {
        guard let major = versionString.split(separator: ".").first,
              let n = Int(major) else { return false }
        return n >= 37
    }
}

/// `EmulatorClient.makeDisplayTransport()` 該建哪種 display transport 的**決策結果**。
public enum DisplayTransportChoice: Equatable, Sendable {
    case mmapWithRawFallback     // >=37：MMAP 為主、raw RGBA 為降級後備
    case rawOnly                 // <37 或版本未知：只用 raw RGBA（36.x 收 MMAP 會 SIGSEGV）
}

/// 依 emulator 版本決定 display transport 的種類。純決策，不建構任何東西、不碰 gRPC，
/// 故可完整單元測試——選路邏輯不該為了被測而去建真 channel（Task 6 審查 Important 1
/// 教訓：先前把選路跟真 `MmapStreamTransport`/`GrpcChannelBox` 的建構綁在一起測，逼得
/// 單元測試建立真實 channel，在完整套件並行執行時把既有 NIO teardown 競態的命中率從
/// 0% 推到約 75%）。`EmulatorClient.makeDisplayTransport()` 呼叫本函式取得結果後，
/// 建構部分退化成一個純 switch。
public enum DisplayTransportSelector {
    public static func choose(emulatorVersion: String) -> DisplayTransportChoice {
        MmapVersionGate.allows(versionString: emulatorVersion) ? .mmapWithRawFallback : .rawOnly
    }
}
