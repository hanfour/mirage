import AppKit
import MirageCore

extension MirrorMTKView: NSTextInputClient {
    func synchronizeTextSession() {
        let next = textInput?.queue.textCoordinator.status.generation
        if let previous = observedGeneration, next != previous { cancelComposition() }
        observedGeneration = next
    }
    func cancelComposition() {
        acceptsTextCallbacks = false
        eventGeneration = nil
        if !session.composition.text.isEmpty { textInput?.localDraft = session.composition.text }
        session.cancel()
        inputContext?.discardMarkedText()
        for codes in ownedKeys.values { for code in codes.reversed() { onKey?(code, false) } }
        ownedKeys.removeAll()
        updateMarkedOverlay()
        compositionChanged?()
    }
    override func resignFirstResponder() -> Bool {
        cancelComposition()
        textInput?.queue.invalidateTextSession()
        return super.resignFirstResponder()
    }
    private func callbackAllowed() -> Bool {
        synchronizeTextSession()
        return textMode && acceptsTextCallbacks && eventGeneration == session.generation
    }
    private func plain(_ value: Any) -> String? {
        (value as? NSAttributedString)?.string ?? value as? String
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard callbackAllowed(), let value = plain(string) else { return }
        eventWasComposing = true
        _ = session.mark(value, selection: selectedRange, replacement: replacementRange)
        publishComposition()
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard callbackAllowed(), let value = plain(string) else { return }
        if let commit = session.insert(value, replacement: replacementRange, token: session.generation) {
            textInput?.submit(commit.text)
        } else if session.composition.text.isEmpty { textInput?.localDraft = value }
        publishComposition()
    }
    func unmarkText() {
        guard callbackAllowed() else { return }
        if let commit = session.unmark(token: session.generation) { textInput?.submit(commit.text) }
        publishComposition()
    }
    private func publishComposition() {
        if !session.composition.text.isEmpty { textInput?.localDraft = session.composition.text }
        textInput?.localIssue = session.composition.issue
        updateMarkedOverlay()
        compositionChanged?()
        inputContext?.invalidateCharacterCoordinates()
    }
    func hasMarkedText() -> Bool { !session.composition.text.isEmpty }
    func markedRange() -> NSRange { session.composition.markedRange }
    func selectedRange() -> NSRange { session.composition.selection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .markedClauseSegment] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard CompositionState.valid(range, in: session.composition.text) else { return nil }
        actualRange?.pointee = range
        return NSAttributedString(string: (session.composition.text as NSString).substring(with: range))
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        if let (rect, actual) = coordinateRect?(range) { actualRange?.pointee = actual; return rect }
        actualRange?.pointee = NSRange(location: 0, length: 0)
        let local = NSRect(x: 8, y: 8, width: 1, height: 20)
        return window?.convertToScreen(convert(local, to: nil)) ?? convert(local, to: nil)
    }
    override func doCommand(by selector: Selector) {
        guard callbackAllowed() else { return }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelComposition(); return }
        // Return can select a candidate; it must never become LINE Send, even after insertText cleared marked state.
        guard !eventWasComposing, !hasMarkedText(), let event = currentTextEvent else { return }
        let keys: [String: String] = ["deleteBackward:": "Backspace", "deleteForward:": "Delete",
            "moveLeft:": "ArrowLeft", "moveRight:": "ArrowRight", "moveUp:": "ArrowUp", "moveDown:": "ArrowDown",
            "moveLeftAndModifySelection:": "ArrowLeft", "moveRightAndModifySelection:": "ArrowRight",
            "moveToBeginningOfLine:": "Home", "moveToEndOfLine:": "End"]
        guard let key = keys[NSStringFromSelector(selector)] else { return }
        let codes: [KeyCode] = (event.modifierFlags.contains(.shift) ? [.key("Shift")] : []) + [.key(key)]
        ownedKeys[event.keyCode] = codes
        for code in codes { onKey?(code, true) }
    }
    @objc func paste(_ sender: Any?) {
        guard textMode, !hasMarkedText(), let text = NSPasteboard.general.string(forType: .string) else { return }
        synchronizeTextSession()
        textInput?.submit(text)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if textMode, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
