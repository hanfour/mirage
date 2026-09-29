import Foundation
import MirageCore
import Testing
@testable import MirageShell

@Suite struct InstanceBannerTests {
    private let avd = "mirage-game"

    @Test func launchingMessage() {
        #expect(InstanceBanner.content(for: .launching(since: Date(timeIntervalSince1970: 0)),
                                       avd: avd)?.text == "啟動模擬器中…")
    }

    @Test func stoppingMessageHasNoActions() throws {
        let content = try #require(InstanceBanner.content(for: .stopping, avd: avd))
        #expect(content.text == "停止模擬器中…")
        #expect(content.color == .progress)
        #expect(!content.showsRestart)
        #expect(!content.showsLog)
    }

    @Test func bootingMessage() {
        #expect(InstanceBanner.content(for: .booting(since: Date(timeIntervalSince1970: 0)),
                                       avd: avd)?.text == "Android 開機中…")
    }

    @Test func restartingMessage() {
        #expect(InstanceBanner.content(for: .restarting, avd: avd)?.text == "模擬器意外結束，重新啟動中…")
    }

    @Test func missingSdkMessageHasNoActions() throws {
        let maybeContent = InstanceBanner.content(
            for: .failed(.emulatorNotFound(URL(fileURLWithPath: "/sdk"))), avd: avd)
        let content = try #require(maybeContent)
        #expect(content.text == "找不到 Android SDK。請重新開啟 Mirage 以執行設定")
        #expect(!content.showsRestart)
        #expect(!content.showsLog)
    }

    @Test func missingAvdNamesTheInstance() {
        let content = InstanceBanner.content(for: .failed(.avdNotFound(URL(fileURLWithPath: "/avd.ini"))),
                                             avd: avd)
        #expect(content?.text == "找不到模擬器 mirage-game。請重新開啟 Mirage 以執行設定")
    }

    @Test func avdInUseMessageNamesTheInstance() {
        let content = InstanceBanner.content(for: .failed(.avdInUse(consolePort: 5556)), avd: avd)
        #expect(content?.text == "mirage-game 已在其他埠上執行")
    }

    @Test func launchTimeoutOffersRestartAndLog() throws {
        let content = try #require(InstanceBanner.content(for: .failed(.launchTimedOut), avd: avd))
        #expect(content.text == "模擬器啟動逾時")
        #expect(content.showsRestart)
        #expect(content.showsLog)
    }

    @Test func bootTimeoutOffersRestartAndLog() throws {
        let content = try #require(InstanceBanner.content(for: .failed(.bootTimedOut), avd: avd))
        #expect(content.text == "Android 開機逾時")
        #expect(content.showsRestart)
        #expect(content.showsLog)
    }

    @Test func abnormalExitOffersRestartAndLog() throws {
        let content = try #require(InstanceBanner.content(for: .failed(.abnormalExit), avd: avd))
        #expect(content.text == "模擬器異常結束")
        #expect(content.showsRestart)
        #expect(content.showsLog)
    }

    @Test func spawnFailureIncludesReasonAndOffersActions() throws {
        let content = try #require(InstanceBanner.content(for: .failed(.spawnFailed("permission denied")),
                                                         avd: avd))
        #expect(content.text == "無法啟動模擬器：permission denied")
        #expect(content.showsRestart)
        #expect(content.showsLog)
    }

    @Test func runningUsesConnectionBanner() {
        #expect(InstanceBanner.content(for: .running, avd: avd) == nil)
    }

    @Test func externalUsesConnectionBanner() {
        #expect(InstanceBanner.content(for: .external, avd: avd) == nil)
    }

    @Test func stoppedUsesConnectionBanner() {
        #expect(InstanceBanner.content(for: .stopped, avd: avd) == nil)
    }

    @Test func nilStateUsesConnectionBanner() {
        #expect(InstanceBanner.content(for: nil, avd: avd) == nil)
    }

    @Test func instanceTableErrorIncludesLineAndReason() {
        let content = InstanceBanner.content(for: InstanceTableError(line: 4, reason: "埠重複"))
        #expect(content.text == "實例表格式錯誤：第 4 行 埠重複")
    }

    @Test func sdkSpecErrorUsesErrorBannerStyle() {
        let content = InstanceBanner.content(for: SdkSpecError(message: "讀取失敗"))
        #expect(content.text == "SDK 設定檔讀取失敗：讀取失敗")
        #expect(content.color == .error)
        #expect(!content.showsRestart)
        #expect(!content.showsLog)
    }
}
