import Foundation
import Testing
@testable import MirageCore

@Suite struct MmapVersionGateTests {
    @Test func rejectsStable36() {
        #expect(!MmapVersionGate.allows(versionString: "36.6.11.0"))
    }

    @Test func acceptsCanary37() {
        #expect(MmapVersionGate.allows(versionString: "37.2.1.0"))
    }

    @Test func acceptsFuture38() {
        #expect(MmapVersionGate.allows(versionString: "38.0.0"))
    }

    @Test func rejectsGarbage() {
        #expect(!MmapVersionGate.allows(versionString: ""))
        #expect(!MmapVersionGate.allows(versionString: "abc"))
        #expect(!MmapVersionGate.allows(versionString: "unknown.1"))
    }
}
