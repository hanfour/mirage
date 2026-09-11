import AppKit
import MirageCore

/// Local TextKit glyphs only; never an editor or a hit-test target.
final class MarkedTextOverlay: NSTextView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func display(_ state: CompositionState, width: CGFloat) {
        isEditable = false; isSelectable = false
        drawsBackground = true; backgroundColor = .windowBackgroundColor
        textContainerInset = NSSize(width: 5, height: 4)
        isHorizontallyResizable = false; isVerticallyResizable = false
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: max(1, width - 10), height: 10000)
        let value = NSMutableAttributedString(string: state.text, attributes: [
            .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue])
        if CompositionState.valid(state.selection, in: state.text), state.selection.length > 0 {
            value.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, range: state.selection)
        }
        textStorage?.setAttributedString(value)
        if let manager = layoutManager, let container = textContainer {
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            setFrameSize(NSSize(width: min(width, max(20, used.maxX + 10)), height: max(28, used.maxY + 8)))
        }
        isHidden = state.text.isEmpty
        needsDisplay = true
    }
    func glyphRect(_ requested: NSRange) -> (NSRect, NSRange) {
        let length = (string as NSString).length
        let range = CompositionState.valid(requested, in: string) ? requested : NSRange(location: length, length: 0)
        guard let manager = layoutManager, let container = textContainer else {
            return (NSRect(x: 5, y: 4, width: 1, height: 22), NSRange(location: 0, length: 0))
        }
        manager.ensureLayout(for: container)
        if range.length > 0 {
            var actual = NSRange()
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: &actual)
            var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
            return (rect, actual)
        }
        if range.location < length {
            let index = manager.glyphIndexForCharacter(at: range.location)
            var rect = manager.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: container)
            rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y; rect.size.width = 1
            return (rect, range)
        }
        if manager.extraLineFragmentTextContainer != nil {
            let rect = manager.extraLineFragmentRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            return (NSRect(x: rect.minX, y: rect.minY, width: 1, height: max(22, rect.height)), range)
        }
        if manager.numberOfGlyphs > 0 {
            let rect = manager.boundingRect(forGlyphRange: NSRange(location: manager.numberOfGlyphs - 1, length: 1), in: container)
            return (NSRect(x: rect.maxX + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y, width: 1, height: max(22, rect.height)), range)
        }
        return (NSRect(x: 5, y: 4, width: 1, height: 22), range)
    }
}

extension MirrorMTKView {
    func updateMarkedOverlay() {
        if markedOverlay.superview == nil { addSubview(markedOverlay) }
        markedOverlay.display(session.composition, width: max(20, bounds.width - 16))
        markedOverlay.frame = CompositionAnchor.frame(point: compositionAnchor, content: bounds.size, overlay: markedOverlay.frame.size)
        coordinateRect = { [weak self] range in
            guard let self else { return (.zero, NSRange(location: NSNotFound, length: 0)) }
            let (rect, actual) = self.markedOverlay.glyphRect(range)
            let windowRect = self.markedOverlay.convert(rect, to: nil)
            return (self.window?.convertToScreen(windowRect) ?? windowRect, actual)
        }
        inputContext?.invalidateCharacterCoordinates()
    }
}
