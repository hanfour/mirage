import Foundation

public enum AvdWriterError: Error, Equatable, LocalizedError, Sendable {
    case missingImagePackage(String)

    public var errorDescription: String? {
        switch self {
        case .missingImagePackage(let manifest): "sdk-spec.json 缺少映像套件：\(manifest)"
        }
    }
}

public enum AvdWriter {
    public static func renderConfig(spec: SdkSpec, avd: SdkAvdSpec, sdkRoot: URL) throws -> String {
        guard let image = spec.packages.first(where: { $0.manifestKey == avd.imageManifest }) else {
            throw AvdWriterError.missingImagePackage(avd.imageManifest)
        }
        let imageDirectory = image.installPath.split(separator: "/").reduce(
            sdkRoot.standardizedFileURL
        ) { directory, component in
            directory.appendingPathComponent(String(component), isDirectory: true)
        }
        var values = spec.configBase
        values.merge([
            "avd.id": avd.name,
            "avd.name": avd.name,
            "image.sysdir.1": imageDirectory.path + "/",
            "PlayStore.enabled": avd.playstore ? "yes" : "no",
            "tag.id": avd.tagId,
            "tag.ids": avd.tagId,
            "tag.display": avd.tagDisplay,
            "tag.displaynames": avd.tagDisplay,
        ]) { _, overlay in overlay }
        return values.keys.sorted().map { "\($0) = \(values[$0]!)\n" }.joined()
    }

    public static func renderPointerIni(spec: SdkSpec, avd: SdkAvdSpec, avdDirectory: URL) -> String {
        let target = spec.configBase["target"] ?? spec.androidTarget
        return [
            "avd.ini.encoding=UTF-8\n",
            "path=\(avdDirectory.path)/\(avd.name).avd\n",
            "path.rel=avd/\(avd.name).avd\n",
            "target=\(target)\n",
        ].joined()
    }

    public static func write(
        spec: SdkSpec,
        avd: SdkAvdSpec,
        sdkRoot: URL,
        avdDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let avdDataDirectory = avdDirectory.appendingPathComponent("\(avd.name).avd", isDirectory: true)
        try fileManager.createDirectory(at: avdDataDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: avdDirectory, withIntermediateDirectories: true)

        let config = try renderConfig(spec: spec, avd: avd, sdkRoot: sdkRoot)
        let pointer = renderPointerIni(spec: spec, avd: avd, avdDirectory: avdDirectory)
        let marker = avdDataDirectory.appendingPathComponent(
            AvdSettings.managedMarkerFilename, isDirectory: false)
        try Data(config.utf8).write(
            to: avdDataDirectory.appendingPathComponent("config.ini", isDirectory: false), options: .atomic)
        try Data(pointer.utf8).write(
            to: avdDirectory.appendingPathComponent("\(avd.name).ini", isDirectory: false), options: .atomic)
        try Data(AvdSettings.managedMarkerContent.utf8).write(to: marker, options: .atomic)
    }
}
