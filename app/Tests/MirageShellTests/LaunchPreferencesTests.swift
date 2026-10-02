import AppKit
import Foundation
import Testing
@testable import MirageShell

// 布林一律用 #expect(x)／#expect(!x)：`#expect(bool == bool)` 在本 repo 永遠不紅（見 D35）。
@Suite struct LaunchPreferencesTests {
    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let (defaults, suite) = try #require(TemporaryDefaults.make("LaunchPreferencesTests"))
        defer { TemporaryDefaults.discard(defaults, suite) }
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

    @Test func smoothFramesDefaultsOnAndSurvivesRecreation() throws {
        try withSuite { defaults in
            let prefs = LaunchPreferences(defaults: defaults, environment: [:])
            #expect(defaults.object(forKey: LaunchPreferences.smoothFramesKey) == nil)
            #expect(prefs.smoothFrames)
            #expect(defaults.object(forKey: LaunchPreferences.smoothFramesKey) == nil)
            prefs.smoothFrames = false
            #expect(!prefs.smoothFrames)
            let recreated = LaunchPreferences(defaults: defaults, environment: [:])
            #expect(!recreated.smoothFrames)
            recreated.smoothFrames = true
            #expect(recreated.smoothFrames)
            #expect(LaunchPreferences(defaults: defaults, environment: [:]).smoothFrames)
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
    // MIRAGE_BACKGROUND_MODE：驗證腳本用來蓋掉使用者的背景模式設定，不寫回儲存值。
    @Test func overrideParserAbsent() {
        let result = LaunchPreferences.backgroundModeOverride([:])
        #expect(result.value == nil)
        #expect(result.problem == nil)
    }

    @Test func overrideParserOneAndZero() throws {
        let on = LaunchPreferences.backgroundModeOverride(["MIRAGE_BACKGROUND_MODE": "1"])
        let onValue = try #require(on.value)
        #expect(onValue)
        #expect(on.problem == nil)
        let off = LaunchPreferences.backgroundModeOverride(["MIRAGE_BACKGROUND_MODE": "0"])
        let offValue = try #require(off.value)
        #expect(!offValue)
        #expect(off.problem == nil)
    }

    @Test func overrideParserRejectsOtherValues() {
        let result = LaunchPreferences.backgroundModeOverride(["MIRAGE_BACKGROUND_MODE": "yes"])
        #expect(result.value == nil)
        #expect(result.problem == "MIRAGE_BACKGROUND_MODE=yes 不是 0 或 1，改用儲存的設定")
    }

    @Test func effectiveFollowsOverrideWhenPresent() throws {
        try withSuite { defaults in
            LaunchPreferences(defaults: defaults).backgroundMode = true
            let forcedOff = LaunchPreferences(defaults: defaults, environment: ["MIRAGE_BACKGROUND_MODE": "0"])
            #expect(!forcedOff.effectiveBackgroundMode)
            #expect(forcedOff.backgroundMode)
            LaunchPreferences(defaults: defaults).backgroundMode = false
            let forcedOn = LaunchPreferences(defaults: defaults, environment: ["MIRAGE_BACKGROUND_MODE": "1"])
            #expect(forcedOn.effectiveBackgroundMode)
        }
    }

    @Test func effectiveFollowsStoredValueWhenAbsent() throws {
        try withSuite { defaults in
            let prefs = LaunchPreferences(defaults: defaults, environment: [:])
            #expect(!prefs.effectiveBackgroundMode)
            prefs.backgroundMode = true
            #expect(prefs.effectiveBackgroundMode)
            let invalid = LaunchPreferences(defaults: defaults, environment: ["MIRAGE_BACKGROUND_MODE": "yes"])
            #expect(invalid.effectiveBackgroundMode)
        }
    }

    @Test func togglingStoredValueDoesNotChangeEffectiveUnderOverride() throws {
        try withSuite { defaults in
            let prefs = LaunchPreferences(defaults: defaults, environment: ["MIRAGE_BACKGROUND_MODE": "0"])
            prefs.backgroundMode = true
            #expect(LaunchPreferences(defaults: defaults).backgroundMode)
            #expect(!prefs.effectiveBackgroundMode)
            prefs.backgroundMode = false
            #expect(!LaunchPreferences(defaults: defaults).backgroundMode)
            #expect(!prefs.effectiveBackgroundMode)
        }
    }
}
