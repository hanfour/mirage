import Foundation
import Testing
@testable import MirageCore

@Suite struct BuiltInProfilesTests {
    /// 這條是 D4 的風險閘門：整個設計建立在「Bundle.module 找得到資源」之上，
    /// 而那件事在動手前沒有被驗證過。先讓它綠，其餘才有意義。
    @Test func bundleContainsSampleProfile() throws {
        let url = Bundle.module.url(forResource: "com.example.game",
                                    withExtension: "json",
                                    subdirectory: "profiles")
        let found = try #require(url, "Bundle.module 找不到 profiles/com.example.game.json——資源沒進 bundle")
        let data = try Data(contentsOf: found)
        let profile = try JSONDecoder().decode(KeymapProfile.self, from: data)
        #expect(profile.gameId == "com.example.game")
    }
}
