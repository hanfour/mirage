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
        guard let characters, !characters.isEmpty else { return nil }
        return .key(characters)
    }
}
