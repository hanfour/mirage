import Foundation

public enum StoreError: Error, Equatable {
    case notFound
    case corrupted
}

/// Profile 持久化：載入 fail-fast（解析→schema 驗證），儲存原子寫（temp+rename）。
public struct ProfileStore: Sendable {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// App 預設位置。
    public static func standard() -> ProfileStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirage/profiles", isDirectory: true)
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

    public func save(_ profile: KeymapProfile) throws {
        let data = try JSONEncoder().encode(profile)
        let dest = url(profile.gameId)
        let tmp = dest.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)   // 原子 rename
    }
}
