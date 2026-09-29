import Foundation

enum MirageResources {
    static let bundle: Bundle = {
        if let url = resolve(
            mainResourceURL: Bundle.main.resourceURL,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        ), let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    static func resolve(mainResourceURL: URL?, fileExists: (URL) -> Bool) -> URL? {
        guard let mainResourceURL else { return nil }
        let bundleURL = mainResourceURL.appendingPathComponent("Mirage_MirageCore.bundle", isDirectory: true)
        return fileExists(bundleURL) ? bundleURL : nil
    }
}
