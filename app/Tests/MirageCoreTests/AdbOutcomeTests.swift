import Testing
@testable import MirageCore

@Suite struct AdbOutcomeTests {
    @Test func zeroExitWithForegroundReturnsPackage() {
        let out = "topResumedActivity=ActivityRecord{a u0 com.example.game/.M t1}"
        #expect(AdbOutcome.packageOrNil(exitCode: 0, stdout: out) == "com.example.game")
    }
    @Test func nonZeroExitDegradesToNil() {
        let out = "topResumedActivity=ActivityRecord{a u0 com.example.game/.M t1}"
        #expect(AdbOutcome.packageOrNil(exitCode: 1, stdout: out) == nil)   // adb 失敗→降級
    }
    @Test func zeroExitNoForegroundIsNil() {
        #expect(AdbOutcome.packageOrNil(exitCode: 0, stdout: "nothing") == nil)
    }
}
