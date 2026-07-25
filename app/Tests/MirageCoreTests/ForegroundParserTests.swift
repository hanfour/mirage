import Testing
@testable import MirageCore

@Suite struct ForegroundParserTests {
    @Test func parsesTopResumedActivity() {
        let out = """
            mResumedActivity: ActivityRecord{a u0 com.example.game/.MainActivity t9}
            topResumedActivity=ActivityRecord{b u0 com.example.game/.MainActivity t9}
            """
        #expect(ForegroundParser.foregroundPackage(fromDumpsys: out) == "com.example.game")
    }

    @Test func parsesLauncherPackage() {
        let out = "  topResumedActivity=ActivityRecord{39cc710 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t16}"
        #expect(ForegroundParser.foregroundPackage(fromDumpsys: out) == "com.android.launcher3")
    }

    @Test func emptyOutputIsNil() {
        #expect(ForegroundParser.foregroundPackage(fromDumpsys: "") == nil)
    }

    @Test func noResumedActivityIsNil() {
        #expect(ForegroundParser.foregroundPackage(fromDumpsys: "Foo: bar\nBaz: qux") == nil)
    }

    @Test func resumedLineWithoutPackageIsNil() {
        #expect(ForegroundParser.foregroundPackage(fromDumpsys: "ResumedActivity: <null>") == nil)
    }
}
