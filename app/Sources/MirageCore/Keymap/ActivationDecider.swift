import Foundation

/// 手動覆蓋狀態：auto=跟隨偵測；force=強制某 profile；disabled=停用 keymap。
public enum ManualOverride: Equatable, Sendable {
    case auto
    case force(KeymapProfile)
    case disabled
}

/// keymap 啟用結果。
public enum Activation: Equatable, Sendable {
    case active(KeymapProfile)
    case inactive
}

/// 純決策：把「該不該啟用、用哪個 profile」與 I/O 分離。App 先對偵測到的 package
/// 做 ProfileStore.load（I/O），把結果與手動覆蓋餵進來。
public enum ActivationDecider {
    public static func decide(loadedProfile: KeymapProfile?, override: ManualOverride) -> Activation {
        switch override {
        case .force(let p): return .active(p)
        case .disabled:     return .inactive
        case .auto:         return loadedProfile.map { .active($0) } ?? .inactive
        }
    }
}
