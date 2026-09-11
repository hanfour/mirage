import Foundation
import Testing
@testable import MirageCore

@Suite struct CompositionStateTests {
    let unspecified = NSRange(location: NSNotFound, length: 0)
    @Test(arguments: ["中文", "👩‍👩‍👧‍👦", "é", "e\u{301}", "🙂"])
    func utf16AndExactContent(_ text: String) {
        var s = CompositionState()
        let result9 = s.update(text, selection: NSRange(location: text.utf16.count, length: 0), replacement: unspecified)
        #expect(result9)
        #expect((s.markedRange.length == text.utf16.count))
        #expect((TextContent.exactlyEqual(s.text, text)))
    }
    @Test func replacementAndInvalidRanges() {
        var s = CompositionState()
        let result15 = s.update("A🙂B", selection: NSRange(location: 1, length: 2), replacement: unspecified)
        #expect(result15)
        let result16 = !s.update("x", selection: NSRange(location: 1, length: 0), replacement: NSRange(location: 2, length: 1))
        #expect(result16)
        #expect((s.text == "A🙂B"))
        #expect((s.issue != nil))
        let result19 = s.update("中", selection: NSRange(location: 2, length: 0), replacement: NSRange(location: 1, length: 2))
        #expect(result19)
        #expect((s.text == "A中B"))
        let result21 = !s.update("x", selection: NSRange(location: 99, length: 0), replacement: unspecified)
        #expect(result21)
        #expect((s.text == "A中B"))
    }
}

@Suite struct TextInputSessionTests {
    let unspecified = NSRange(location: NSNotFound, length: 0)
    @Test func finalizeOnceAndSameTextTwice() throws {
        var s = TextInputSession()
        for text in ["ㄓ", "中", "中文"] {
            let result31 = s.mark(text, selection: NSRange(location: text.utf16.count, length: 0), replacement: unspecified)
            #expect(result31)
        }
        let result33 = s.insert("中文", replacement: unspecified, token: s.generation)
        let first = try #require(result33)
        let result34 = s.unmark(token: s.generation) == nil
        #expect(result34)
        let result35 = s.mark("中文", selection: NSRange(location: 2, length: 0), replacement: unspecified)
        #expect(result35)
        let result36 = s.unmark(token: s.generation)
        let second = try #require(result36)
        #expect((first.id != second.id))
        #expect((first.text == second.text))
        let result39 = s.unmark(token: s.generation) == nil
        #expect(result39)
    }
    @Test func cancellationAndUnsupportedGuestRange() {
        var s = TextInputSession()
        let token = s.generation
        let result44 = s.mark("中", selection: NSRange(location: 1, length: 0), replacement: unspecified)
        #expect(result44)
        let result45 = s.insert("文", replacement: NSRange(location: 90, length: 1), token: token) == nil
        #expect(result45)
        #expect((s.composition.text == "中"))
        s.cancel()
        let result48 = s.unmark(token: token) == nil
        #expect(result48)
        let result49 = s.insert("late", replacement: unspecified, token: token) == nil
        #expect(result49)
    }
}
