import Foundation
import MirageCore

enum InstanceBanner {
    enum ColorCategory: Equatable {
        case progress
        case warning
        case error
    }

    struct Content: Equatable {
        let text: String
        let color: ColorCategory
        let showsRestart: Bool
        let showsLog: Bool
    }

    static func content(for state: InstanceState?, avd: String) -> Content? {
        guard let state else { return nil }
        switch state {
        case .launching:
            return Content(text: "啟動模擬器中…", color: .progress,
                           showsRestart: false, showsLog: false)
        case .stopping:
            return Content(text: "停止模擬器中…", color: .progress,
                           showsRestart: false, showsLog: false)
        case .booting:
            return Content(text: "Android 開機中…", color: .progress,
                           showsRestart: false, showsLog: false)
        case .restarting:
            return Content(text: "模擬器意外結束，重新啟動中…", color: .warning,
                           showsRestart: false, showsLog: false)
        case .failed(let failure):
            switch failure {
            case .emulatorNotFound:
                return Content(text: "找不到 Android SDK。請重新開啟 Mirage 以執行設定",
                               color: .error, showsRestart: false, showsLog: false)
            case .avdNotFound:
                return Content(text: "找不到模擬器 \(avd)。請重新開啟 Mirage 以執行設定",
                               color: .error, showsRestart: false, showsLog: false)
            case .avdInUse:
                return Content(text: "\(avd) 已在其他埠上執行", color: .error,
                               showsRestart: false, showsLog: false)
            case .launchTimedOut:
                return Content(text: "模擬器啟動逾時", color: .error,
                               showsRestart: true, showsLog: true)
            case .bootTimedOut:
                return Content(text: "Android 開機逾時", color: .error,
                               showsRestart: true, showsLog: true)
            case .abnormalExit:
                return Content(text: "模擬器異常結束", color: .error,
                               showsRestart: true, showsLog: true)
            case .spawnFailed(let reason):
                return Content(text: "無法啟動模擬器：\(reason)", color: .error,
                               showsRestart: true, showsLog: true)
            case .insufficientDisk(let availableMB, let neededMB):
                return Content(
                    text: "磁碟空間不足：需要 \(gigabytes(neededMB)) GB，可用 \(gigabytes(availableMB)) GB",
                    color: .error, showsRestart: false, showsLog: true)
            }
        case .stopped, .running, .external:
            return nil
        }
    }

    static func content(for error: InstanceTableError) -> Content {
        Content(text: "實例表格式錯誤：第 \(error.line) 行 \(error.reason)", color: .error,
                showsRestart: false, showsLog: false)
    }

    static func content(for error: SdkSpecError) -> Content {
        Content(text: "SDK 設定檔讀取失敗：\(error.message)", color: .error,
                showsRestart: false, showsLog: false)
    }

    private static func gigabytes(_ megabytes: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"),
               arguments: [megabytes / 1024])
    }
}
