import Foundation
import CoreGraphics
import Testing
import MirageCore

@Suite struct CompositionAnchorTests {
    @Test func normalizedAnchorTracksContentAndClamps() {
        let small = CompositionAnchor.frame(point: CGPoint(x: 0.5, y: 0.5), content: CGSize(width: 300, height: 500), overlay: CGSize(width: 100, height: 30))
        #expect(small.origin == CGPoint(x: 150, y: 250))
        let large = CompositionAnchor.frame(point: CGPoint(x: 0.5, y: 0.5), content: CGSize(width: 600, height: 1000), overlay: CGSize(width: 100, height: 30))
        #expect(large.origin == CGPoint(x: 300, y: 500))
        let edge = CompositionAnchor.frame(point: CGPoint(x: 1, y: 1), content: CGSize(width: 300, height: 500), overlay: CGSize(width: 100, height: 30))
        #expect(edge.maxX <= 300 && edge.maxY <= 500)
        let fallback = CompositionAnchor.frame(point: nil, content: CGSize(width: 300, height: 500), overlay: CGSize(width: 100, height: 30))
        #expect(fallback.minX > 0 && fallback.minY > 0)
    }
}
