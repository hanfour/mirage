import Testing
@testable import MirageCore

@Suite struct KeyTranslateTests {
    /// 一般可列印字元走字元路徑——要版面感知（Shift+2 在美式版面是 "@"）。
    @Test func printableCharacterPassesThrough() {
        #expect(KeyTranslate.w3c(virtualKey: 0, characters: "a", hasCommand: false) == .key("a"))
        #expect(KeyTranslate.w3c(virtualKey: 19, characters: "@", hasCommand: false) == .key("@"))
        #expect(KeyTranslate.w3c(virtualKey: 49, characters: " ", hasCommand: false) == .key(" "))
    }

    /// 特殊鍵走虛擬鍵碼路徑——charactersIgnoringModifiers 對 Enter 給 "\r"、
    /// 對方向鍵給私用區字元，都不是 emulator 認得的 W3C 值。
    @Test func specialKeysMapByVirtualKeyCode() {
        #expect(KeyTranslate.w3c(virtualKey: 36, characters: "\r", hasCommand: false) == .key("Enter"))
        #expect(KeyTranslate.w3c(virtualKey: 51, characters: "\u{7f}", hasCommand: false) == .key("Backspace"))
        #expect(KeyTranslate.w3c(virtualKey: 48, characters: "\t", hasCommand: false) == .key("Tab"))
        #expect(KeyTranslate.w3c(virtualKey: 123, characters: nil, hasCommand: false) == .key("ArrowLeft"))
        #expect(KeyTranslate.w3c(virtualKey: 124, characters: nil, hasCommand: false) == .key("ArrowRight"))
        #expect(KeyTranslate.w3c(virtualKey: 125, characters: nil, hasCommand: false) == .key("ArrowDown"))
        #expect(KeyTranslate.w3c(virtualKey: 126, characters: nil, hasCommand: false) == .key("ArrowUp"))
    }

    /// Esc 送 GoBack 而非 Escape：設計 D-4，兌現 P1-e 設計文件「Esc 在 guest 是返回鍵」。
    /// 兩者實測都送得到（KEY_ESC / KEY_BACK），這是刻意的產品選擇不是技術限制。
    @Test func escapeBecomesAndroidBack() {
        #expect(KeyTranslate.w3c(virtualKey: 53, characters: "\u{1b}", hasCommand: false) == .key("GoBack"))
    }

    /// ⌘ 組合一律不直通：Android 沒有 ⌘，且 ⌘C/⌘V 已有剪貼簿橋接負責，
    /// 送過去會貼兩次。特殊鍵也一樣擋——⌘Enter 不該變成 guest 的 Enter。
    @Test func commandCombinationsAreNeverForwarded() {
        #expect(KeyTranslate.w3c(virtualKey: 8, characters: "c", hasCommand: true) == nil)
        #expect(KeyTranslate.w3c(virtualKey: 36, characters: "\r", hasCommand: true) == nil)
        #expect(KeyTranslate.w3c(virtualKey: 126, characters: nil, hasCommand: true) == nil)
        #expect(KeyTranslate.w3c(virtualKey: 125, characters: nil, hasCommand: true) == nil)
    }

    /// 沒有字元又不是已知特殊鍵 → nil，不猜。
    @Test func unknownKeyWithoutCharactersIsDropped() {
        #expect(KeyTranslate.w3c(virtualKey: 999, characters: nil, hasCommand: false) == nil)
        #expect(KeyTranslate.w3c(virtualKey: 999, characters: "", hasCommand: false) == nil)
    }

    /// D19：功能鍵的 `charactersIgnoringModifiers` 是私用區字元，既不是 nil 也不是空字串。
    /// 這些值取自 AppKit 的 `NSF1FunctionKey` 等常數，是實測列印確認過的。
    /// 舊版會把它們原樣送給 guest，而 emulator 必不認得，靜默無作用。
    @Test func privateUseAreaCharactersAreDropped() {
        let functionKeys: [(String, Unicode.Scalar)] = [
            ("F1", "\u{F704}"), ("ForwardDelete", "\u{F728}"), ("Home", "\u{F729}"),
            ("End", "\u{F72B}"), ("PageUp", "\u{F72C}"), ("PageDown", "\u{F72D}"),
        ]
        for (name, scalar) in functionKeys {
            let result = KeyTranslate.w3c(virtualKey: 999,
                                          characters: String(Character(scalar)),
                                          hasCommand: false)
            #expect(result == nil, "\(name) 的私用區字元不該被送出")
        }
    }

    /// 私用區的另外兩段（第 15、16 平面）也要擋。macOS 目前不用它們，
    /// 但判準寫成「私用區」就該完整，少列會變成另一個「只涵蓋想得到的那些」的清單。
    @Test func supplementaryPrivateUsePlanesAreDropped() {
        #expect(KeyTranslate.w3c(virtualKey: 999, characters: "\u{F0000}", hasCommand: false) == nil)
        #expect(KeyTranslate.w3c(virtualKey: 999, characters: "\u{100000}", hasCommand: false) == nil)
    }

    /// 控制字元同理：有字元但不可列印。
    @Test func controlCharactersAreDropped() {
        #expect(KeyTranslate.w3c(virtualKey: 999, characters: "\u{01}", hasCommand: false) == nil)
        #expect(KeyTranslate.w3c(virtualKey: 999, characters: "\u{7F}", hasCommand: false) == nil)
    }

    /// **判準刻意只擋控制字元與私用區**，一般字元照舊送出，包含非 ASCII。
    /// 2026-07-29 的實測推翻了 proto「只保證可列印 ASCII」的說法，
    /// 把非 ASCII 一併擋掉會是超出 D19 範圍的行為變更。
    @Test func ordinaryCharactersStillPassThrough() {
        #expect(KeyTranslate.w3c(virtualKey: 0, characters: "a", hasCommand: false) == .key("a"))
        #expect(KeyTranslate.w3c(virtualKey: 49, characters: " ", hasCommand: false) == .key(" "))
        #expect(KeyTranslate.w3c(virtualKey: 999, characters: "é", hasCommand: false) == .key("é"))
    }
}
