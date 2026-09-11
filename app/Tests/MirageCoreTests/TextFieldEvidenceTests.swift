import Foundation
import Testing
@testable import MirageCore

@Suite struct TextFieldEvidenceTests {
    private func sample(_ text: String, focus: Bool = true, fresh: Bool = true, time: Double = 20) -> TextFieldSnapshot {
        TextFieldSnapshot(package: "test.app", field: "test.app:id/edit", className: "android.widget.EditText",
                          focused: focus, text: text, rawText: text, bounds: [0,0,100,40], capturedAt: time, fresh: fresh)
    }
    @Test(arguments: ["LEFTRIGHT中文🙂", "中文🙂", "LEFT中文🙂", "中文🙂RIGHT", "LEFTold中文🙂RIGHT"])
    func clipboardCannotProveInsertionOrReplacement(_ wrong: String) {
        #expect(!TextFieldEvidence.matches(sample(wrong), expected: "LEFT中文🙂RIGHT", package: "test.app", field: "test.app:id/edit", notBefore: 10, clipboard: "LEFT中文🙂RIGHT"))
    }
    @Test func exactPositionAndUnicodeAreRequired() {
        #expect(TextFieldEvidence.matches(sample("LEFT中文🙂RIGHT"), expected: "LEFT中文🙂RIGHT", package: "test.app", field: "test.app:id/edit", notBefore: 10))
        #expect(!TextFieldEvidence.matches(sample("é"), expected: "e\u{301}", package: "test.app", field: "test.app:id/edit", notBefore: 10, clipboard: "e\u{301}"))
    }
    @Test func nullStaleWrongFocusOrWrongTargetIsInvalid() {
        for snapshot in [nil, sample("ok",focus:false),sample("ok",fresh:false),sample("ok",time:9)] {
            #expect(!TextFieldEvidence.matches(snapshot, expected: "ok", package: "test.app", field: "test.app:id/edit", notBefore: 10, clipboard: "ok"))
        }
        #expect(!TextFieldEvidence.matches(sample("ok"), expected: "ok", package: "other", field: "test.app:id/edit", notBefore: 10, clipboard: "ok"))
    }
}
