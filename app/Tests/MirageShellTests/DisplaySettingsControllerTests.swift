import Foundation
import MirageCore
import Testing
@testable import MirageShell

@MainActor
@Suite struct DisplaySettingsControllerTests {
    @Test(arguments: [FrameSinkSource.setting, .environment])
    func persistsSettingWithoutChangingStartupSource(source: FrameSinkSource) throws {
        let (defaults, suite) = try #require(TemporaryDefaults.make("DisplaySettingsControllerTests"))
        defer { TemporaryDefaults.discard(defaults, suite) }
        let preferences = LaunchPreferences(defaults: defaults, environment: [:])
        let controller = DisplaySettingsController(
            launchPreferences: preferences, frameSinkSource: source)

        #expect(controller.smoothFrames)
        #expect(defaults.object(forKey: LaunchPreferences.smoothFramesKey) == nil)
        controller.smoothFrames = false
        #expect(!preferences.smoothFrames)
        let recreated = DisplaySettingsController(
            launchPreferences: LaunchPreferences(defaults: defaults, environment: [:]),
            frameSinkSource: source)
        #expect(!recreated.smoothFrames)
        recreated.smoothFrames = true
        #expect(preferences.smoothFrames)
        #expect(controller.frameSinkSource == source)
        #expect(recreated.frameSinkSource == source)
    }
}
