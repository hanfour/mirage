import Foundation
import CoreGraphics

/// Normalized AppKit content coordinates (y points upward), never Android/backing pixels.
public enum CompositionAnchor {
    public static func frame(point: CGPoint?, content: CGSize, overlay: CGSize) -> CGRect {
        let width = max(0, min(overlay.width, content.width))
        let height = max(0, min(overlay.height, content.height))
        let valid = point.flatMap { p in
            p.x.isFinite && p.y.isFinite && (0...1).contains(p.x) && (0...1).contains(p.y) ? p : nil
        }
        let x = valid.map { $0.x * content.width } ?? 8
        let y = valid.map { $0.y * content.height } ?? 8
        return CGRect(x: max(0, min(x, content.width - width)),
                      y: max(0, min(y, content.height - height)), width: width, height: height)
    }
}
