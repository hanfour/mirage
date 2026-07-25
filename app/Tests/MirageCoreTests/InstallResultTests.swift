import Testing
@testable import MirageCore

@Suite struct InstallResultTests {
    @Test func plainSuccess() {
        #expect(InstallResult.parse("Success") == .success)
    }
    @Test func streamedSuccess() {
        #expect(InstallResult.parse("Performing Streamed Install\nSuccess") == .success)
    }
    @Test func failureBracketReason() {
        #expect(InstallResult.parse("Failure [INSTALL_FAILED_ALREADY_EXISTS]")
            == .failure("INSTALL_FAILED_ALREADY_EXISTS"))
    }
    @Test func adbErrorPrefixWithBracket() {
        let out = "adb: failed to install x.apk: Failure [INSTALL_FAILED_INVALID_APK: Failed to parse]"
        #expect(InstallResult.parse(out) == .failure("INSTALL_FAILED_INVALID_APK: Failed to parse"))
    }
    @Test func failedNoBracket() {
        let out = "adb: failed to install x.apk: no devices/emulators found"
        #expect(InstallResult.parse(out)
            == .failure("adb: failed to install x.apk: no devices/emulators found"))
    }
    @Test func emptyIsUnknown() {
        #expect(InstallResult.parse("") == .failure("未知錯誤"))
        #expect(InstallResult.parse("   \n ") == .failure("未知錯誤"))
    }
    @Test func unknownFormatReturnsTrimmed() {
        #expect(InstallResult.parse("weird output") == .failure("weird output"))
    }
    // 串流進度 `[ 50%]` 不得誤判成 failure（只有 "Failure [" 才觸發括號抽取）
    @Test func progressBracketNotMistakenForFailure() {
        #expect(InstallResult.parse("[ 50%] /data/local/tmp/x.apk\nSuccess") == .success)
    }
    @Test func failureBracketEmptyReason() {
        #expect(InstallResult.parse("Failure []") == .failure("未知錯誤"))
    }
}
