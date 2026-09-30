import Testing
@testable import MirageCore

@Suite("InsufficientDiskLogParser")
struct InsufficientDiskLogParserTests {
    @Test func parsesEmulatorUserdataSpaceFailure() throws {
        let line = "FATAL | Not enough space to create userdata partition. Available: 5190.41 MB at /var/folders/…/mirage-game.avd, need 9830.40 MB."

        let space = try #require(InsufficientDiskLogParser.parse(line))

        #expect(space.availableMB == 5190.41)
        #expect(space.neededMB == 9830.40)
    }

    @Test func ignoresUnrelatedFatalLog() {
        #expect(InsufficientDiskLogParser.parse("FATAL | Missing system image.") == nil)
    }
}
