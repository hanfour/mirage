import Foundation

public enum StoreError: Error, Equatable {
    case notFound
    case corrupted
}

/// Profile 持久化：載入 fail-fast（解析→schema 驗證），儲存原子寫（temp+rename）。
public struct ProfileStore: Sendable {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// App 預設的 profile 目錄。
    ///
    /// 公開是因為 seeding（`BuiltInProfiles`）的目的地必須與這裡讀取的目錄**是同一個**。
    /// 讓呼叫端自己拼一次 "Mirage/profiles" 會產生第二份複本，而兩份同樣的知識遲早漂移
    /// ——這個 repo 剛因為 `EmulatorEndpoint` 的解析有兩份而吃過虧。
    public static func standardDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirage/profiles", isDirectory: true)
    }

    /// App 預設位置。
    public static func standard() -> ProfileStore {
        let base = standardDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return ProfileStore(directory: base)
    }

    private func url(_ gameId: String) -> URL {
        directory.appendingPathComponent("\(gameId).json")
    }

    public func load(gameId: String) throws -> KeymapProfile {
        let u = url(gameId)
        guard FileManager.default.fileExists(atPath: u.path) else { throw StoreError.notFound }
        let data = try Data(contentsOf: u)
        let profile: KeymapProfile
        do {
            profile = try JSONDecoder().decode(KeymapProfile.self, from: data)
        } catch {
            throw StoreError.corrupted
        }
        return try profile.validated()      // schema 驗證失敗擲 ProfileError（不吞）
    }

    /// **存檔前先驗證**（2026-07-30，D5 階段 B 終審 I2）：`load` 會 `validated()` 而 `save`
    /// 不會，於是「存得進去、載不出來」的 profile 有機會被寫上磁碟；而 load 端的錯誤又被
    /// `AppModel.applyActivation` 的 `try?` 吞掉，使用者只會看到「keymap 就是不生效」，
    /// 壞檔永久留在磁碟且沒有 UI 路徑回得去（⌘E 開的是新 starter，不是那個壞檔）。
    ///
    /// 放在 `save` 裡而不是各呼叫端，才涵蓋得到所有寫入路徑。階段 B 現有的寫入路徑都有
    /// 夾取，但夾取只擋得住數值範圍——擋不住 schema 層的結構約束（例如兩個 joystick 的
    /// `identifierConflict`），而階段 C 的「新增 binding」必然會碰到那一類。
    public func save(_ profile: KeymapProfile) throws {
        let checked = try profile.validated()
        let data = try JSONEncoder().encode(checked)
        let dest = url(checked.gameId)
        let tmp = dest.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)   // 原子 rename
    }
}
