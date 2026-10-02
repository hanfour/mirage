import Foundation
import Testing
@testable import MirageCore

@Suite("MiragePaths")
struct MiragePathsTests {
    private let home = URL(fileURLWithPath: "/users/tester", isDirectory: true)

    @Test func sdkRootPrefersSdkRootThenAndroidHomeThenMirageDefault() {
        #expect(MiragePaths.sdkRoot(
            environment: ["ANDROID_SDK_ROOT": "/sdk-root", "ANDROID_HOME": "/android-home"],
            homeDirectory: home).path == "/sdk-root")
        #expect(MiragePaths.sdkRoot(
            environment: ["ANDROID_HOME": "/android-home"],
            homeDirectory: home).path == "/android-home")
        #expect(MiragePaths.sdkRoot(environment: [:], homeDirectory: home).path ==
                "/users/tester/Library/Application Support/Mirage/sdk")
    }

    @Test func emptyEnvironmentValuesFallBackToMirageDirectories() {
        #expect(MiragePaths.sdkRoot(
            environment: ["ANDROID_SDK_ROOT": "", "ANDROID_HOME": ""],
            homeDirectory: home).path == "/users/tester/Library/Application Support/Mirage/sdk")
        #expect(MiragePaths.avdDirectory(
            environment: ["ANDROID_AVD_HOME": ""],
            homeDirectory: home).path == "/users/tester/Library/Application Support/Mirage/avd")
    }

    @Test func avdOverrideAndDownloadCacheResolveUnderHome() {
        #expect(MiragePaths.avdDirectory(
            environment: ["ANDROID_AVD_HOME": "/custom/avds"],
            homeDirectory: home).path == "/custom/avds")
        #expect(MiragePaths.downloadsDirectory(homeDirectory: home).path ==
                "/users/tester/Library/Caches/Mirage/downloads")
        #expect(MiragePaths.locationSettingsFile(homeDirectory: home).path ==
                "/users/tester/Library/Application Support/Mirage/location.json")
    }
}
