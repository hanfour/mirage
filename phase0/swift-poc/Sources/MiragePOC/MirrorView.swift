// phase0/swift-poc/Sources/MiragePOC/MirrorView.swift
import AppKit
import MetalKit

final class MirrorView: MTKView {
    var renderer: Renderer?
    var onMouse: ((_ nx: Double, _ ny: Double, _ down: Bool) -> Void)?

    func present(_ frame: Frame) {
        renderer?.upload(frame, into: self)
    }

    private func normalized(_ event: NSEvent) -> (Double, Double)? {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        // ADAPTED (API mismatch vs. brief, documented in task-8-report.md):
        // NSView geometry (`p`, `bounds`) is CGFloat; brief's snippet implicitly
        // typed nx/ny as Double, which does not compile (CGFloat/Double don't
        // auto-convert in tuple return position). Explicit Double() casts added.
        let nx = Double(p.x / bounds.width)
        let ny = 1.0 - Double(p.y / bounds.height)  // AppKit y 朝上，guest y 朝下
        guard (0...1).contains(nx), (0...1).contains(ny) else { return nil }
        return (nx, ny)
    }

    override func mouseDown(with event: NSEvent) {
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, true) }
    }
    override func mouseDragged(with event: NSEvent) {
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, true) }
    }
    override func mouseUp(with event: NSEvent) {
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, false) }
    }
}
