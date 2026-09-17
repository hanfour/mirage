import AppKit
import Foundation
import Testing
@testable import MirageShell

// 布林一律用 #expect(x)／#expect(!x)：`#expect(bool == bool)` 在本 repo 永遠不紅（見 D35）。
@Suite struct LaunchPreferencesTests {
    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "LaunchPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func defaultsAreOff() throws {
        try withSuite { defaults in
            let prefs = LaunchPreferences(defaults: defaults)
            #expect(!prefs.backgroundMode)
            #expect(!prefs.speechEnabled)
        }
    }

    @Test func valuesSurviveRecreation() throws {
        try withSuite { defaults in
            let prefs = LaunchPreferences(defaults: defaults)
            prefs.backgroundMode = true
            prefs.speechEnabled = true
            let recreated = LaunchPreferences(defaults: defaults)
            #expect(recreated.backgroundMode)
            #expect(recreated.speechEnabled)
            recreated.backgroundMode = false
            #expect(!LaunchPreferences(defaults: defaults).backgroundMode)
            #expect(LaunchPreferences(defaults: defaults).speechEnabled)
        }
    }

    @Test func windowStepAfterStart() {
        #expect(LaunchPreferences.windowStepAfterStart(backgroundMode: false, remoteStarted: false) == .keep)
        #expect(LaunchPreferences.windowStepAfterStart(backgroundMode: false, remoteStarted: true) == .keep)
        #expect(LaunchPreferences.windowStepAfterStart(backgroundMode: true, remoteStarted: true) == .suspendHidden)
        // 遙控沒開起來還藏著視窗，使用者就什麼都看不到，也看不到選單列的錯誤原因。
        #expect(LaunchPreferences.windowStepAfterStart(backgroundMode: true, remoteStarted: false) == .reshow)
    }

    @Test func activationPolicyFollowsBackgroundMode() {
        #expect(LaunchPreferences.launchActivationPolicy(backgroundMode: true) == .accessory)
        #expect(LaunchPreferences.launchActivationPolicy(backgroundMode: false) == .regular)
        // 顯示視窗一律 regular：accessory 身分的視窗拿不到鍵盤焦點與主選單快捷鍵。
        #expect(LaunchPreferences.policyAfterWindowHidden(backgroundMode: true) == .accessory)
        #expect(LaunchPreferences.policyAfterWindowHidden(backgroundMode: false) == nil)
    }
}
