import Foundation

/// NSEvent 的欄位 → 要送給 guest 的 W3C key。純函式，刻意不吃 `NSEvent`——
/// AppKit 型別無法在 MirageCore 單元測試，而「哪顆鍵該送什麼」正是唯一值得測的部分。
/// 比照 `ForegroundParser`／`ActivationDecider`／`StreamSize` 的既有慣例。
///
/// 傳輸端只走 `KeyboardEvent.key`（W3C 字串）。2026-07-29 在活模擬器上用
/// `adb shell getevent -l` 實測：a／Enter／Backspace／Tab／Escape／方向鍵／
/// GoBack／GoHome／AppSwitch 十個鍵全部送達，推翻 proto 自己「只保證可列印 ASCII」
/// 的保守說法。完整數據見 `docs/specs/2026-07-29-d2-keyboard-passthrough-design.md` §2。
public enum KeyTranslate {
    /// macOS 虛擬鍵碼 → W3C key。**用鍵碼不用字元**：字元隨鍵盤版面變，
    /// 而「哪顆實體鍵」不變；且 `charactersIgnoringModifiers` 對這些鍵給的是
    /// 控制字元或私用區字元（Enter → "\r"、方向鍵 → U+F700 區段），emulator 不認得。
    ///
    /// 空白鍵**刻意不列入**：它的字元 " " 本身就是合法的 W3C key（實測送達），
    /// 走一般字元路徑即可，多一個表項只是多一個要維護的地方。
    ///
    /// 鍵碼來源：Carbon HIToolbox `Events.h` 的 `kVK_*`。
    static let specialKeys: [UInt16: String] = [
        36: "Enter",        // kVK_Return
        48: "Tab",          // kVK_Tab
        51: "Backspace",    // kVK_Delete（macOS 的 Delete 鍵是退格）
        53: "GoBack",       // kVK_Escape → Android 返回鍵（設計 D-4）
        123: "ArrowLeft",
        124: "ArrowRight",
        125: "ArrowDown",
        126: "ArrowUp",
    ]

    /// - Parameters:
    ///   - virtualKey: `NSEvent.keyCode`
    ///   - characters: `NSEvent.charactersIgnoringModifiers`
    ///   - hasCommand: `NSEvent.modifierFlags.contains(.command)`
    /// - Returns: 要直通的鍵；`nil` 代表不送（⌘ 組合，或無法辨識）。
    public static func w3c(virtualKey: UInt16,
                           characters: String?,
                           hasCommand: Bool) -> KeyCode? {
        // ⌘ 一律不送。放在最前面：即使是已知特殊鍵也擋，⌘Enter 不該變成 guest 的 Enter。
        if hasCommand { return nil }
        if let special = specialKeys[virtualKey] { return .key(special) }
        guard let characters, isForwardable(characters) else { return nil }
        return .key(characters)
    }

    /// 這串字元能不能原樣當成 W3C key 送給 guest。
    ///
    /// **存在的理由（D19）**：原本只檢查「非 nil 且非空」，而 macOS 對功能鍵給的
    /// `charactersIgnoringModifiers` 是**私用區字元**——F1 是 U+F704、ForwardDelete 是
    /// U+F728、Home 是 U+F729、End 是 U+F72B、PageUp 是 U+F72C、PageDown 是 U+F72D。
    /// 它們既不是 nil 也不是空字串，於是整批被當成 W3C key 送出去，而 emulator 必不認得。
    /// 後果是靜默無作用不是崩潰，但它讓上面那句「不猜」變成假的：碼確實在猜，
    /// 只是猜在另一個分支。
    ///
    /// 判準刻意只擋兩類，不擋更多：控制字元與私用區字元。**不限制成 ASCII**——
    /// 2026-07-29 的實測推翻了 proto 自己「只保證可列印 ASCII」的說法，
    /// 把非 ASCII 一併擋掉會是超出這個缺陷範圍的行為變更。
    static func isForwardable(_ characters: String) -> Bool {
        guard !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            !isControl(scalar) && !isPrivateUse(scalar)
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F)
    }

    /// 三個私用區：BMP 的 U+E000–U+F8FF，以及第 15、16 平面。
    /// macOS 的功能鍵用的是第一段，另外兩段一併列出是因為判準寫成「私用區」就該完整，
    /// 少列會變成另一個「只涵蓋想得到的那些」的清單（本專案的 D19 就是這樣來的）。
    private static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0xE000...0xF8FF).contains(v)
            || (0xF0000...0xFFFFD).contains(v)
            || (0x100000...0x10FFFD).contains(v)
    }
}
