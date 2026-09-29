import Foundation

public struct SdkPackageSpec: Codable, Equatable, Sendable {
    public let manifestKey: String
    public let path: String
    public let channel: String
    public let revision: String
    public let sha1: String
    public let size: Int64
    public let installPath: String
    public let url: URL
}

public struct SdkAvdSpec: Codable, Equatable, Sendable {
    public let name: String
    public let imageManifest: String
    public let playstore: Bool
    public let tagId: String
    public let tagDisplay: String
}

public struct SdkSpec: Codable, Equatable, Sendable {
    public let androidTarget: String
    public let packages: [SdkPackageSpec]
    public let avds: [SdkAvdSpec]
    public let configBase: [String: String]

    public static func decode(_ data: Data) -> Result<SdkSpec, SdkSpecError> {
        do {
            return .success(try JSONDecoder().decode(SdkSpec.self, from: data))
        } catch {
            return .failure(SdkSpecError(message: "sdk-spec.json 格式錯誤：\(error.localizedDescription)"))
        }
    }

    public static func bundled() -> Result<SdkSpec, SdkSpecError> {
        guard let url = Bundle.module.url(forResource: "sdk-spec", withExtension: "json")
            ?? Bundle.module.url(forResource: "sdk-spec", withExtension: "json", subdirectory: "Resources")
        else {
            return .failure(SdkSpecError(message: "找不到內建的 Resources/sdk-spec.json"))
        }
        do {
            return decode(try Data(contentsOf: url))
        } catch {
            return .failure(SdkSpecError(message: "讀取內建 sdk-spec.json 失敗：\(error.localizedDescription)"))
        }
    }
}

public struct SdkSpecError: Error, Equatable, LocalizedError, Sendable {
    public let message: String

    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}
