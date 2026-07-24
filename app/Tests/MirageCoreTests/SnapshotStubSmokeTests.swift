import Testing
@testable import MirageCore

@Suite struct SnapshotStubSmokeTests {
    @Test func snapshotPackageFieldsExist() {
        var pkg = Android_Emulation_Control_SnapshotPackage()
        pkg.snapshotID = "mirage_suspend"
        pkg.format = .directory
        #expect(pkg.snapshotID == "mirage_suspend")
        #expect(pkg.format == .directory)
    }
}
