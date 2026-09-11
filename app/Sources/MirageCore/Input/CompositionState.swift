import Foundation

/// Only the local preedit document. Ranges never describe the guest document.
public struct CompositionState: Sendable {
    public private(set) var text = ""
    public private(set) var selection = NSRange(location: 0, length: 0)
    public private(set) var issue: String?
    public init() {}
    public var markedRange: NSRange { text.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: text.utf16.count) }
    public static func valid(_ range: NSRange, in text: String) -> Bool {
        let units = Array(text.utf16)
        guard range.location >= 0, range.length >= 0, range.location <= units.count,
              range.length <= units.count - range.location else { return false }
        func boundary(_ offset: Int) -> Bool {
            offset == 0 || offset == units.count || !(0xDC00...0xDFFF).contains(units[offset])
        }
        return boundary(range.location) && boundary(range.location + range.length)
    }
    public mutating func update(_ value: String, selection: NSRange, replacement: NSRange) -> Bool {
        let range = replacement.location == NSNotFound ? NSRange(location: 0, length: text.utf16.count) : replacement
        guard Self.valid(range, in: text) else {
            issue = "Unsupported replacement outside local preedit"; return false
        }
        let next = (text as NSString).replacingCharacters(in: range, with: value)
        guard Self.valid(selection, in: next) else {
            issue = "Invalid UTF-16 selection"; return false
        }
        text = next; self.selection = selection; issue = nil
        return true
    }
    public mutating func clear() { self = Self() }
}
