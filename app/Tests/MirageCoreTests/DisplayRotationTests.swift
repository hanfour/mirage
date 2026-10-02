import Testing
@testable import MirageCore

@Suite struct DisplayRotationTests {
    private let corners = [
        NormPoint(x: 0, y: 0), NormPoint(x: 1, y: 0),
        NormPoint(x: 0, y: 1), NormPoint(x: 1, y: 1),
    ]

    @Test func mapsAllFourCornersForEveryRotation() {
        let expected: [[NormPoint]] = [
            corners,
            [NormPoint(x: 1, y: 0), NormPoint(x: 1, y: 1),
             NormPoint(x: 0, y: 0), NormPoint(x: 0, y: 1)],
            [NormPoint(x: 1, y: 1), NormPoint(x: 0, y: 1),
             NormPoint(x: 1, y: 0), NormPoint(x: 0, y: 0)],
            [NormPoint(x: 0, y: 1), NormPoint(x: 0, y: 0),
             NormPoint(x: 1, y: 1), NormPoint(x: 1, y: 0)],
        ]

        for rotation in 0..<4 {
            for (index, point) in corners.enumerated() {
                #expect(DisplayRotation.panelPoint(fromUpright: point, rotation: rotation)
                        == expected[rotation][index])
            }
        }
    }

    @Test func panelAndUprightConversionsAreInverses() {
        let points = [NormPoint(x: 0, y: 0), NormPoint(x: 1, y: 1),
                      NormPoint(x: 0.17, y: 0.83), NormPoint(x: 0.5, y: 0.25)]
        for rotation in 0..<4 {
            for point in points {
                let panel = DisplayRotation.panelPoint(fromUpright: point, rotation: rotation)
                let returned = DisplayRotation.uprightPoint(fromPanel: panel, rotation: rotation)
                #expect(abs(returned.x - point.x) < 1e-12)
                #expect(abs(returned.y - point.y) < 1e-12)
            }
        }
    }

    @Test func swapsUprightDimensionsOnlyForQuarterTurns() {
        #expect(DisplayRotation.upright(size: (w: 1080, h: 2400), rotation: 0).w == 1080)
        #expect(DisplayRotation.upright(size: (w: 1080, h: 2400), rotation: 0).h == 2400)
        #expect(DisplayRotation.upright(size: (w: 1080, h: 2400), rotation: 1).w == 2400)
        #expect(DisplayRotation.upright(size: (w: 1080, h: 2400), rotation: 1).h == 1080)
        #expect(DisplayRotation.upright(size: (w: 1080, h: 2400), rotation: 2).w == 1080)
        #expect(DisplayRotation.upright(size: (w: 1080, h: 2400), rotation: 2).h == 2400)
        #expect(DisplayRotation.upright(size: (w: 1080, h: 2400), rotation: 3).w == 2400)
        #expect(DisplayRotation.upright(size: (w: 1080, h: 2400), rotation: 3).h == 1080)
    }
}
