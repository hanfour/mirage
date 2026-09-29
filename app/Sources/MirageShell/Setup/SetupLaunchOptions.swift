import Foundation
import MirageCore

struct SetupLaunchOptions: Equatable {
    static let specFileKey = "MIRAGE_SDK_SPEC_FILE"
    static let autostartKey = "MIRAGE_SETUP_AUTOSTART"
    static let availableBytesKey = "MIRAGE_SETUP_FAKE_AVAILABLE_BYTES"

    let specFile: URL?
    let autostart: Bool
    let fakeAvailableBytes: Int64?
    let warnings: [String]

    static func parse(environment: [String: String]) -> SetupLaunchOptions {
        var warnings: [String] = []

        let specFile: URL?
        if let raw = environment[specFileKey] {
            if raw.isEmpty {
                warnings.append("\(specFileKey) 是空值，已忽略")
                specFile = nil
            } else {
                specFile = URL(fileURLWithPath: raw)
            }
        } else {
            specFile = nil
        }

        let autostart: Bool
        switch environment[autostartKey] {
        case nil, "0": autostart = false
        case "1": autostart = true
        case let raw?:
            warnings.append("\(autostartKey)=\(oneLine(raw)) 不是 0 或 1，已忽略")
            autostart = false
        }

        let fakeAvailableBytes: Int64?
        if let raw = environment[availableBytesKey] {
            if let parsed = Int64(raw), parsed >= 0 {
                fakeAvailableBytes = parsed
            } else {
                warnings.append("\(availableBytesKey)=\(oneLine(raw)) 不是非負整數，已忽略")
                fakeAvailableBytes = nil
            }
        } else {
            fakeAvailableBytes = nil
        }

        return SetupLaunchOptions(specFile: specFile, autostart: autostart,
                                  fakeAvailableBytes: fakeAvailableBytes, warnings: warnings)
    }

    private static func oneLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    func loadSdkSpec(bundled: () -> Result<SdkSpec, SdkSpecError> = SdkSpec.bundled) -> Result<SdkSpec, SdkSpecError> {
        guard let specFile else { return bundled() }
        do {
            return SdkSpec.decode(try Data(contentsOf: specFile))
        } catch {
            return .failure(SdkSpecError(message: "讀取 sdk-spec.json 失敗：\(error.localizedDescription)"))
        }
    }
}
