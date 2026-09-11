import Foundation

enum TextEvidenceDirectory {
    static func requireFresh(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
            guard names.allSatisfy({ $0 == "swift-live.log" }) else {
                throw CocoaError(.fileWriteFileExists)
            }
        }
    }
}
