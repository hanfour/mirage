import Testing
@testable import MirageShell

@MainActor
private final class FakeClipboard: ClipboardReading {
    var changeCount = 10
    var text: String? = "initial"
    var reads = 0
    func plainText() -> String? { reads += 1; return text }
}

@MainActor
struct ClipboardWatcherTests {
    @Test func changedTextNotifies() {
        let board = FakeClipboard()
        var changes: [String] = []
        let watcher = ClipboardWatcher(pasteboard: board) { changes.append($0) }
        board.changeCount += 1
        board.text = "new"
        watcher.poll()
        #expect(changes == ["new"])
    }

    @Test func nonTextAdvancesBaselineWithoutCallback() {
        let board = FakeClipboard()
        var changes: [String] = []
        let watcher = ClipboardWatcher(pasteboard: board) { changes.append($0) }
        board.changeCount += 1
        board.text = nil
        watcher.poll()
        watcher.poll()
        #expect(changes.isEmpty)
        #expect(board.reads == 1)
    }

    @Test func unchangedCountDoesNotReadOrNotify() {
        let board = FakeClipboard()
        var changes: [String] = []
        let watcher = ClipboardWatcher(pasteboard: board) { changes.append($0) }
        watcher.poll()
        #expect(changes.isEmpty)
        #expect(board.reads == 0)
    }

    // spec §4.3 依 changeCount 判定變更，相同文字重新複製仍應回呼。
    @Test func repeatedContentWithNewCountNotifies() {
        let board = FakeClipboard()
        var changes: [String] = []
        let watcher = ClipboardWatcher(pasteboard: board) { changes.append($0) }
        board.changeCount += 1
        watcher.poll()
        watcher.poll()
        board.changeCount += 1
        watcher.poll()
        #expect(changes == ["initial", "initial"])
    }

    @Test func syncBaselineSkipsLocalWrite() {
        let board = FakeClipboard()
        var changes: [String] = []
        let watcher = ClipboardWatcher(pasteboard: board) { changes.append($0) }
        board.changeCount += 1
        watcher.syncBaseline()
        watcher.poll()
        #expect(changes.isEmpty)
        board.changeCount += 1
        watcher.poll()
        #expect(changes == ["initial"])
    }
}
