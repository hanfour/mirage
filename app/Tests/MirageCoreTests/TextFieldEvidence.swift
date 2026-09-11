import Foundation

struct TextFieldSnapshot: Codable, Sendable {
    let package: String
    let field: String
    let className: String
    let focused: Bool
    let text: String
    let rawText: String
    let bounds: [Int]
    let capturedAt: Double
    let fresh: Bool
}

enum TextFieldEvidence {
    static func matches(_ snapshot: TextFieldSnapshot?, expected: String, package: String, field: String,
                        notBefore: Double, clipboard: String? = nil) -> Bool {
        guard let snapshot, snapshot.fresh, snapshot.capturedAt >= notBefore,
              snapshot.package == package, snapshot.field == field,
              snapshot.className == "android.widget.EditText", snapshot.focused,
              snapshot.bounds.count == 4 else { return false }
        return snapshot.text.utf8.elementsEqual(expected.utf8)
    }
}
