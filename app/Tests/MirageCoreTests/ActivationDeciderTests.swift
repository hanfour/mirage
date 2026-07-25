import Testing
@testable import MirageCore

@Suite struct ActivationDeciderTests {
    private func profile(_ id: String) -> KeymapProfile {
        KeymapProfile(gameId: id, version: 1, bindings: [.tap(key: .key("j"), at: NormPoint(x: 0.5, y: 0.5))])
    }

    @Test func autoWithProfileActivates() {
        let p = profile("g")
        #expect(ActivationDecider.decide(loadedProfile: p, override: .auto) == .active(p))
    }

    @Test func autoWithoutProfileInactive() {
        #expect(ActivationDecider.decide(loadedProfile: nil, override: .auto) == .inactive)
    }

    @Test func forceOverridesDetection() {
        let forced = profile("forced")
        // 即使無偵測 profile，force 仍啟用被強制者
        #expect(ActivationDecider.decide(loadedProfile: nil, override: .force(forced)) == .active(forced))
    }

    @Test func disabledIsInactiveEvenWithProfile() {
        #expect(ActivationDecider.decide(loadedProfile: profile("g"), override: .disabled) == .inactive)
    }
}
