import Testing
@testable import MirageCore

@Suite struct PairingTokenTests {
    @Test func selectionReusesValidValueUnlessRotationRequested() throws {
        let old = try #require(PairingToken(value: "00112233445566778899aabbccddeeff"))
        let replacement = PairingToken.generate(randomBytes: { count in Array(repeating: 0xaa, count: count) })
        #expect(PairingToken.selected(existing: old.value, rotate: false, replacement: replacement) == old)
        #expect(PairingToken.selected(existing: old.value, rotate: true, replacement: replacement) == replacement)
        #expect(PairingToken.selected(existing: nil, rotate: false, replacement: replacement) == replacement)
        #expect(PairingToken.selected(existing: "bad", rotate: false, replacement: replacement) == replacement)
    }

    @Test func generateUsesSixteenInjectedBytesAsLowercaseHex() {
        var requested: [Int] = []
        let token = PairingToken.generate { count in
            requested.append(count)
            return Array(0..<UInt8(count)).map { $0 &* 17 }
        }
        #expect(requested == [16])
        #expect(token.value == "00112233445566778899aabbccddeeff")
        #expect(token.value.count == 32)
    }

    @Test func systemRandomProducesDistinctTokens() {
        let a = PairingToken.generate()
        let b = PairingToken.generate()
        #expect(a != b)
        #expect(PairingToken(value: a.value) == a)
    }

    @Test(arguments: [
        "", "0011", "00112233445566778899AABBCCDDEEFF",
        "00112233445566778899aabbccddeef", "00112233445566778899aabbccddeeffa",
        "0011223344556677889gaabbccddeeff", "00 12233445566778899aabbccddeeff",
    ])
    func initRejectsMalformedValues(_ raw: String) {
        #expect(PairingToken(value: raw) == nil)
    }

    @Test func matchesOnlyTheExactValue() throws {
        let token = try #require(PairingToken(value: "00112233445566778899aabbccddeeff"))
        #expect(token.matches("00112233445566778899aabbccddeeff"))
        #expect(!token.matches(nil))
        #expect(!token.matches(""))
        #expect(!token.matches("00112233445566778899aabbccddeef"))
        #expect(!token.matches("00112233445566778899aabbccddeeffa"))
        #expect(!token.matches("00112233445566778899aabbccddeefe"))
        #expect(!token.matches("00112233445566778899AABBCCDDEEFF"))
    }
}
