import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct PairingTokenStoreTests {
    @Test func recreatedStoreKeepsTokenAndRotationReplacesStoredValue() throws {
        let suite = "PairingTokenStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PairingTokenStore(defaults: defaults, environment: [:]).token()
        let recreated = PairingTokenStore(defaults: defaults, environment: [:])
        #expect(recreated.token() == first)
        let rotated = recreated.token(rotate: true)
        #expect(rotated != first)
        #expect(defaults.string(forKey: PairingTokenStore.key) == rotated.value)
        #expect(PairingTokenStore(defaults: defaults, environment: [:]).token() == rotated)
    }

    @Test func environmentOverridesWithoutOverwritingSavedValue() throws {
        let suite = "PairingTokenStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = PairingToken.generate()
        defaults.set(saved.value, forKey: PairingTokenStore.key)
        let override = "00112233445566778899aabbccddeeff"
        let store = PairingTokenStore(defaults: defaults, environment: [RemoteLaunchOptions.tokenKey: override])
        #expect(store.token().value == override)
        #expect(store.token(rotate: true).value == override)
        #expect(defaults.string(forKey: PairingTokenStore.key) == saved.value)
        #expect(PairingTokenStore(defaults: defaults, environment: [RemoteLaunchOptions.tokenKey: "bad"]).token() == saved)
        let entries = RemoteMenu.entries(.on(urls: [], session: .initial), canRotateToken: false)
        #expect(entries.contains(.rotateToken(enabled: false)))
    }
}
