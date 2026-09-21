import Foundation
import Testing
@testable import MirageShell

@Suite struct TemporaryDefaultsTests {
    /// 測試留下的 suite 不能在 `~/Library/Preferences` 累積空殼。
    @Test func discardRemovesTheFileNotJustItsContents() throws {
        let made = try #require(TemporaryDefaults.make("TemporaryDefaultsTests"))
        made.defaults.set("value", forKey: "key")
        CFPreferencesAppSynchronize(made.suite as CFString)
        let url = TemporaryDefaults.fileURL(for: made.suite)
        // 先確認這一輪真的落盤了，否則後面的斷言證明不了任何事。
        #expect(FileManager.default.fileExists(atPath: url.path))
        TemporaryDefaults.discard(made.defaults, made.suite)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
