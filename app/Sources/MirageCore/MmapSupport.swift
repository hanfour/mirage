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
