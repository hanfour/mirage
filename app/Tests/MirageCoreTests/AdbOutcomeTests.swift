import Foundation
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

    @Test func parsesRotationFromBrotatoFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/rotation/activities-brotato-rot1.txt")
        let stdout = try String(contentsOf: url, encoding: .utf8)
        #expect(AdbOutcome.rotationOrNil(stdout: stdout) == 1)
    }

    @Test func parsesRotationFromHomeFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/rotation/activities-home-rot0.txt")
        let stdout = try String(contentsOf: url, encoding: .utf8)
        #expect(AdbOutcome.rotationOrNil(stdout: stdout) == 0)
    }

    @Test func ignoresWindowConfigurationRotationNames() {
        let stdout = "mGlobalConfig={winConfig={mRotation=ROTATION_90}}"
        #expect(AdbOutcome.rotationOrNil(stdout: stdout) == nil)
    }

    @Test func missingRotationIsNil() {
        #expect(AdbOutcome.rotationOrNil(stdout: "no display rotation") == nil)
    }

    @Test func outOfRangeRotationIsNil() {
        #expect(AdbOutcome.rotationOrNil(stdout: "    mRotation=7 mDeferredRotationPauseCount=0") == nil)
    }
}
