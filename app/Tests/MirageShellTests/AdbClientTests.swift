import Foundation
import Testing
import MirageCore
@testable import MirageShell

struct AdbClientTests {
    // 抄自 app/RESULTS-apk-install.md 的活體輸出，不自行編造 ActivityRecord。
    static let foreground = "      topResumedActivity=ActivityRecord{39cc710 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t16}"

    @Test func foregroundAndCommand() async {
        let client = AdbClient(adbPath: URL(fileURLWithPath: "/sdk/adb"), serial: "device-7") { path, args, timeout, merge in
            #expect(path.path == "/sdk/adb")
            #expect(args == ["-s", "device-7", "shell", "dumpsys", "activity", "activities"])
            #expect(timeout == .seconds(3))
            #expect(!merge)
            return (0, Self.foreground)
        }
        #expect(await client.dumpsysForegroundPackage(timeout: .seconds(3)) == "com.android.launcher3")
    }

    @Test(arguments: ["", String(foreground.prefix(60))])
    func missingOrTruncatedForeground(output: String) async {
        let client = AdbClient(adbPath: URL(fileURLWithPath: "/adb"), serial: "s") { _, _, _, _ in (0, output) }
        #expect(await client.dumpsysForegroundPackage() == nil)
    }

    @Test func foregroundNonzeroExit() async {
        let client = AdbClient(adbPath: URL(fileURLWithPath: "/adb"), serial: "s") { _, _, _, _ in (1, Self.foreground) }
        #expect(await client.dumpsysForegroundPackage() == nil)
    }

    @Test func foregroundTimeout() async {
        let client = AdbClient(adbPath: URL(fileURLWithPath: "/adb"), serial: "s") { _, _, _, _ in nil }
        #expect(await client.dumpsysForegroundPackage() == nil)
    }

    // 成功輸出同樣抄自 app/RESULTS-apk-install.md「補測」的活體輸出。
    @Test func installSuccessAndCommand() async {
        let client = AdbClient(adbPath: URL(fileURLWithPath: "/sdk/adb"), serial: "device-7") { path, args, timeout, merge in
            #expect(path.path == "/sdk/adb")
            #expect(args == ["-s", "device-7", "install", "-r", "/tmp/game.apk"])
            #expect(timeout == .seconds(9))
            #expect(merge)
            return (0, "Performing Streamed Install\nSuccess\n")
        }
        #expect(await client.install(apkURL: URL(fileURLWithPath: "/tmp/game.apk"), timeout: .seconds(9)) == .success)
    }

    // 沿用既有 InstallResultTests 的失敗樣本格式，這是結果注入，非本輪活體紀錄。
    @Test func installFailure() async {
        let client = AdbClient(adbPath: URL(fileURLWithPath: "/adb"), serial: "s") { _, _, _, _ in
            (1, "Failure [INSTALL_FAILED_ALREADY_EXISTS]")
        }
        #expect(await client.install(apkURL: URL(fileURLWithPath: "/game.apk")) == .failure("INSTALL_FAILED_ALREADY_EXISTS"))
    }

    @Test func installTimeout() async {
        let client = AdbClient(adbPath: URL(fileURLWithPath: "/adb"), serial: "s") { _, _, _, _ in nil }
        #expect(await client.install(apkURL: URL(fileURLWithPath: "/game.apk")) == .failure("adb 執行失敗或逾時"))
    }

    // 保留原行為：install 依輸出判讀，即使 exit 非零也不新增判斷。
    @Test func installNonzeroExitUsesOutput() async {
        let client = AdbClient(adbPath: URL(fileURLWithPath: "/adb"), serial: "s") { _, _, _, _ in (1, "Success\n") }
        #expect(await client.install(apkURL: URL(fileURLWithPath: "/game.apk")) == .success)
    }

    @Test func standardMissingExecutable() {
        let client = AdbClient.standard(serial: "s", environment: ["ANDROID_SDK_ROOT": "/missing-sdk"]) { path in
            #expect(path == "/missing-sdk/platform-tools/adb")
            return false
        }
        #expect(client == nil)
    }

    @Test func standardUsesHomeSdkWhenEnvironmentIsEmpty() throws {
        let client = try #require(AdbClient.standard(
            serial: "s",
            environment: ["ANDROID_SDK_ROOT": "", "ANDROID_HOME": ""],
            homeDirectory: URL(fileURLWithPath: "/users/tester", isDirectory: true),
            isExecutable: { path in
                #expect(path == "/users/tester/Library/Android/sdk/platform-tools/adb")
                return true
            }))
        #expect(client.adbPath.path == "/users/tester/Library/Android/sdk/platform-tools/adb")
    }
}
