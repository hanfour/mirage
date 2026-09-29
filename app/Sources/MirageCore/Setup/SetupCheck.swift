import Foundation
import FoundationXML

public struct SetupMissingItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case package(installPath: String)
        case avd(name: String)
    }

    public let kind: Kind
    public let name: String
    public let size: Int64

    public init(kind: Kind, name: String, size: Int64) {
        self.kind = kind
        self.name = name
        self.size = size
    }
}

public struct SetupVersionWarning: Equatable, Sendable {
    public let packageName: String
    public let expectedRevision: String
    public let installedRevision: String?
    public let message: String
}

public struct SetupCheckResult: Equatable, Sendable {
    public let missing: [SetupMissingItem]
    public let warnings: [SetupVersionWarning]
}

public enum SetupCheck {
    private static let provenanceFile = ".mirage-provision.json"

    public static func evaluate(
        spec: SdkSpec,
        sdkRoot: URL,
        avdDirectory: URL,
        fileExists: (URL) -> Bool,
        readFile: (URL) throws -> String
    ) -> SetupCheckResult {
        let game = spec.avds.first(where: { $0.name == "mirage-game" })
        let packages = spec.packages.filter { package in
            package.path == "emulator" || package.path == "platform-tools"
                || package.manifestKey == game?.imageManifest
        }
        var missing: [SetupMissingItem] = []
        var warnings: [SetupVersionWarning] = []

        for package in packages {
            let packageDirectory = sdkRoot.appendingPathComponent(package.installPath, isDirectory: true)
            guard fileExists(packageDirectory) else {
                missing.append(SetupMissingItem(
                    kind: .package(installPath: package.installPath),
                    name: packageDisplayName(package, target: spec.androidTarget),
                    size: package.size))
                continue
            }

            let packageXML = packageDirectory.appendingPathComponent("package.xml", isDirectory: false)
            let installedRevision: String?
            if fileExists(packageXML) {
                installedRevision = readRevision(at: packageXML, readFile: readFile)
            } else {
                installedRevision = recordedRevision(
                    installPath: package.installPath, sdkRoot: sdkRoot,
                    fileExists: fileExists, readFile: readFile)
            }

            if installedRevision != package.revision {
                let shown = installedRevision ?? "無法讀取"
                warnings.append(SetupVersionWarning(
                    packageName: packageDisplayName(package, target: spec.androidTarget),
                    expectedRevision: package.revision,
                    installedRevision: installedRevision,
                    message: "\(packageDisplayName(package, target: spec.androidTarget)) 版本為 \(shown)，預期 \(package.revision)；保留現有安裝。"))
            }
        }

        if let game {
            let pointer = avdDirectory.appendingPathComponent("\(game.name).ini", isDirectory: false)
            let config = avdDirectory
                .appendingPathComponent("\(game.name).avd", isDirectory: true)
                .appendingPathComponent("config.ini", isDirectory: false)
            if !fileExists(pointer) && !fileExists(config) {
                missing.append(SetupMissingItem(
                    kind: .avd(name: game.name), name: "\(game.name) AVD", size: 0))
            }
        }

        return SetupCheckResult(missing: missing, warnings: warnings)
    }

    private static func packageDisplayName(_ package: SdkPackageSpec, target: String) -> String {
        switch package.path {
        case "emulator": "Android Emulator"
        case "platform-tools": "Android Platform Tools"
        default: "Android \(target) Google Play system image"
        }
    }

    private static func readRevision(at url: URL, readFile: (URL) throws -> String) -> String? {
        do {
            let parser = LocalPackageRevisionParser()
            let xml = XMLParser(data: Data(try readFile(url).utf8))
            xml.delegate = parser
            guard xml.parse() else { return nil }
            return parser.revision
        } catch {
            return nil
        }
    }

    private static func recordedRevision(
        installPath: String,
        sdkRoot: URL,
        fileExists: (URL) -> Bool,
        readFile: (URL) throws -> String
    ) -> String? {
        let recordURL = sdkRoot.appendingPathComponent(provenanceFile, isDirectory: false)
        guard fileExists(recordURL), let text = try? readFile(recordURL),
              let data = text.data(using: .utf8),
              let records = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return records[installPath]
    }
}

private final class LocalPackageRevisionParser: NSObject, XMLParserDelegate {
    private var depth = 0
    private var localPackageDepth: Int?
    private var revisionDepth: Int?
    private var activePart: String?
    private var activeText = ""
    private var parts: [String: String] = [:]
    private var didEnterLocalPackage = false

    var revision: String? {
        guard let major = parts["major"], !major.isEmpty else { return nil }
        var components = [major]
        if let minor = parts["minor"], !minor.isEmpty {
            components.append(minor)
            if let micro = parts["micro"], !micro.isEmpty { components.append(micro) }
        }
        return components.joined(separator: ".")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        depth += 1
        if elementName == "localPackage", localPackageDepth == nil, !didEnterLocalPackage {
            localPackageDepth = depth
            didEnterLocalPackage = true
        } else if elementName == "revision", let localPackageDepth,
                  depth == localPackageDepth + 1, revisionDepth == nil {
            revisionDepth = depth
        } else if let revisionDepth, depth == revisionDepth + 1,
                  ["major", "minor", "micro"].contains(elementName) {
            activePart = elementName
            activeText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activePart != nil { activeText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if activePart == elementName {
            parts[elementName] = activeText.trimmingCharacters(in: .whitespacesAndNewlines)
            activePart = nil
            activeText = ""
        }
        if revisionDepth == depth, elementName == "revision" { revisionDepth = nil }
        if localPackageDepth == depth, elementName == "localPackage" { localPackageDepth = nil }
        depth -= 1
    }
}
