import Foundation

/// MMAP 傳輸的純函式支援：路徑產生、handle 組裝、全零判定與取樣指紋。
/// 全部無副作用、無 I/O，故可完整單元測試。
public enum MmapSupport {
    /// RGBA8888 的緩衝區位元組數。任一維度 <= 0 → 0（呼叫端據此拒絕掛載）。
    public static func byteCount(width: Int, height: Int) -> Int {
        rgbaByteCount(width: width, height: height) ?? 0
    }

    static func rgbaByteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { return nil }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return byteOverflow ? nil : bytes
    }

    /// 依通知回報的實際尺寸取映射緩衝區開頭的緊密排列 RGBA 像素。
    /// emulator 可能回傳比請求少一列或一欄，超過映射長度或尺寸為零時回傳 nil。
    public static func frame(width: Int, height: Int, buffer: Data) -> Frame? {
        guard let bytes = rgbaByteCount(width: width, height: height), bytes <= buffer.count else {
            return nil
        }
        let rgba = bytes == buffer.count ? buffer : Data(buffer.prefix(bytes))
        return Frame(width: width, height: height, rgba: rgba)
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

    /// 以每 64 位元組一個取樣點計算 FNV 指紋，與 mirage-pull 的量測方式一致。
    public static func fingerprint(of data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for index in stride(from: 0, to: data.count, by: 64) {
            hash ^= UInt64(data[index])
            hash &*= 1_099_511_628_211
        }
        return hash
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

/// 偵測通知持續抵達、但映射內容沒有改變的狀態機。只收指紋、時間與外層比對結果，
/// 不執行 gRPC 或讀取映射區，方便用固定時間值單元測試冷卻行為。
struct MmapStallDetector {
    enum Decision: Equatable {
        case deliver
        case compareRaw(repeatedNotifications: Int)
    }

    enum RawComparison: Equatable {
        case same
        case different
        case failed(String)
        case incomparable(width: Int, height: Int)
    }

    enum Resolution: Equatable {
        case continueMmap
        case unusable(repeatedNotifications: Int)
        case comparisonFailed(String)
        case incomparable(width: Int, height: Int)
    }

    private let frameThreshold: Int
    private let cooldown: TimeInterval
    private var previousFingerprint: UInt64?
    private var repeatedNotifications = 0
    private var comparisonAllowedAt: TimeInterval?

    init(frameThreshold: Int = 120, cooldown: TimeInterval = 30) {
        self.frameThreshold = frameThreshold
        self.cooldown = cooldown
    }

    mutating func observe(fingerprint: UInt64, at now: TimeInterval) -> Decision {
        if previousFingerprint == fingerprint {
            repeatedNotifications += 1
        } else {
            previousFingerprint = fingerprint
            repeatedNotifications = 1
        }

        guard repeatedNotifications >= frameThreshold,
              comparisonAllowedAt.map({ now >= $0 }) ?? true else {
            return .deliver
        }
        return .compareRaw(repeatedNotifications: repeatedNotifications)
    }

    mutating func resolve(_ comparison: RawComparison, at now: TimeInterval) -> Resolution {
        let repeated = repeatedNotifications
        previousFingerprint = nil
        repeatedNotifications = 0

        switch comparison {
        case .same:
            comparisonAllowedAt = now + cooldown
            return .continueMmap
        case .different:
            return .unusable(repeatedNotifications: repeated)
        case .failed(let message):
            return .comparisonFailed(message)
        case .incomparable(let width, let height):
            return .incomparable(width: width, height: height)
        }
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
    case rawOnly                 // <37、版本未知或 MIRAGE_TRANSPORT=raw
}

/// 依 emulator 版本與環境變數決定 display transport。純決策，不建構 transport 或 gRPC。
/// emulator 37 以上預設使用 MMAP 並保留 raw RGBA 降級；`MIRAGE_TRANSPORT=raw` 強制 raw，
/// `mmap` 與未設定相同。其他值由呼叫端視為未設定並記錄一次警告。
/// 2026-10-01 重測（898×1996）raw 為 59.3–60.0 fps、MMAP 為 59.6–59.9 fps，接收端 CPU
/// 為 34.7–36.4% 對 12.6–13.1%；grpc-swift 畫面恢復的原因仍未查明。
public enum DisplayTransportSelector {
    public static func choose(
        emulatorVersion: String,
        transportOverride: String?
    ) -> DisplayTransportChoice {
        guard transportOverride != "raw",
              MmapVersionGate.allows(versionString: emulatorVersion) else {
            return .rawOnly
        }
        return .mmapWithRawFallback
    }
}
