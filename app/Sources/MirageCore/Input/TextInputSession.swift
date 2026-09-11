import Foundation

public struct TextInputSession: Sendable {
    public private(set) var composition = CompositionState()
    public private(set) var generation: UInt64 = 0
    public init() {}
    public mutating func mark(_ text: String, selection: NSRange, replacement: NSRange) -> Bool { composition.update(text, selection: selection, replacement: replacement) }
    public mutating func insert(_ text: String, replacement: NSRange, token: UInt64) -> TextCommit? {
        guard token == generation else { return nil }
        let offset = replacement.location == NSNotFound ? 0 : replacement.location
        guard offset <= composition.text.utf16.count,
              composition.update(text, selection: NSRange(location: offset + text.utf16.count, length: 0), replacement: replacement)
        else { return nil }
        return unmark(token: token)
    }
    public mutating func unmark(token: UInt64) -> TextCommit? {
        guard token == generation, !composition.text.isEmpty, composition.issue == nil else { return nil }
        let commit = TextCommit(text: composition.text, generation: generation)
        composition.clear()
        return commit
    }
    public mutating func cancel() { composition.clear(); generation &+= 1 }
}
