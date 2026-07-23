import Foundation
import Testing
@testable import MirageCore

@Suite struct FramePumpTests {
    private func frame(_ tag: UInt8) -> Frame {
        Frame(width: 1, height: 1, rgba: Data([tag, 0, 0, 255]))
    }

    @Test func testPumpConsumesStreamIntoBox() async throws {
        let box = LatestFrameBox()
        let pump = FramePump()
        let (stream, cont) = AsyncThrowingStream<Frame, Error>.makeStream()
        await pump.attach(stream, into: box, onEnd: { _ in })
        cont.yield(frame(7))
        cont.finish()
        try await Task.sleep(for: .milliseconds(200))
        #expect(box.takeLatest() == frame(7))
    }

    @Test func testOnEndReceivesStreamError() async throws {
        struct Boom: Error {}
        let box = LatestFrameBox()
        let pump = FramePump()
        let (stream, cont) = AsyncThrowingStream<Frame, Error>.makeStream()
        let holder = ErrorHolder()
        await pump.attach(stream, into: box, onEnd: { err in
            Task { await holder.set(err) }
        })
        cont.finish(throwing: Boom())
        // Deadline polling: check up to ~5 seconds
        var found = false
        for _ in 0..<50 {
            let got = await holder.value
            if got != nil {
                #expect(got is Boom)
                found = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(found)
    }

    @Test func testReattachCancelsPreviousConsumer() async throws {
        let box = LatestFrameBox()
        let pump = FramePump()
        let (s1, c1) = AsyncThrowingStream<Frame, Error>.makeStream()
        let (s2, c2) = AsyncThrowingStream<Frame, Error>.makeStream()
        await pump.attach(s1, into: box, onEnd: { _ in })
        await pump.attach(s2, into: box, onEnd: { _ in })  // 換源
        c1.yield(frame(1))   // 舊源已取消，不應進 box
        c2.yield(frame(2))
        try await Task.sleep(for: .milliseconds(200))
        #expect(box.takeLatest() == frame(2))
    }
}

actor ErrorHolder {
    var value: Error?
    func set(_ e: Error?) { value = e }
}
