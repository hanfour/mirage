import MirageCore
import Observation

/// 畫面設定立即儲存，但不替換這次啟動已選定的幀接收端。
@MainActor
@Observable
final class DisplaySettingsController {
    var smoothFrames: Bool {
        didSet { launchPreferences.smoothFrames = smoothFrames }
    }
    let frameSinkSource: FrameSinkSource

    @ObservationIgnored private let launchPreferences: LaunchPreferences

    init(launchPreferences: LaunchPreferences, frameSinkSource: FrameSinkSource) {
        self.launchPreferences = launchPreferences
        self.frameSinkSource = frameSinkSource
        smoothFrames = launchPreferences.smoothFrames
    }
}
