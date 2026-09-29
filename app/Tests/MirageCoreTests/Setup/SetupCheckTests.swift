import Foundation
import Testing
@testable import MirageCore

@Suite("SetupCheck")
struct SetupCheckTests {
    private let sdkRoot = URL(fileURLWithPath: "/tmp/setup-sdk", isDirectory: true)
    private let avdDirectory = URL(fileURLWithPath: "/tmp/setup-avd", isDirectory: true)

    @Test func reportsThreePackagesAndGameAvdWhenEverythingIsMissing() throws {
        let spec = try SdkSpec.bundled().get()
        let result = check(spec: spec, files: [:])
        #expect(result.missing.count == 4)
        #expect(result.missing.filter {
            if case .package = $0.kind { return true }
            return false
        }.count == 3)
        #expect(result.missing.contains { $0.kind == .avd(name: "mirage-game") })
        #expect(result.warnings.isEmpty)
    }

    @Test func reportsNothingWhenPackagesAndAvdExistAtExpectedVersions() throws {
        let spec = try SdkSpec.bundled().get()
        let result = check(spec: spec, files: installedFiles(spec))
        #expect(result.missing.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test func reportsOnlyTheAvdWhenAllRequiredPackagesExist() throws {
        let spec = try SdkSpec.bundled().get()
        let result = check(spec: spec, files: installedFiles(spec, includeAvd: false))
        #expect(result.missing == [SetupMissingItem(kind: .avd(name: "mirage-game"),
                                                    name: "mirage-game AVD", size: 0)])
        #expect(result.warnings.isEmpty)
    }

    @Test func versionMismatchWarnsWithoutMarkingPackageMissing() throws {
        let spec = try SdkSpec.bundled().get()
        let emulator = try #require(spec.packages.first { $0.path == "emulator" })
        let files = installedFiles(spec, revisions: [emulator.installPath: "37.0.0"])
        let result = check(spec: spec, files: files)
        #expect(result.missing.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].installedRevision == "37.0.0")
    }

    @Test func packageXmlTakesPriorityOverProvenanceRecord() throws {
        let spec = try SdkSpec.bundled().get()
        let emulator = try #require(spec.packages.first { $0.path == "emulator" })
        var files = installedFiles(spec, revisions: [emulator.installPath: "37.0.0"])
        files[sdkRoot.appendingPathComponent(".mirage-provision.json").path] =
            "{\"\(emulator.installPath)\":\"\(emulator.revision)\"}"
        let result = check(spec: spec, files: files)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].installedRevision == "37.0.0")
    }

    @Test func provenanceRecordIsUsedWhenPackageXmlIsAbsent() throws {
        let spec = try SdkSpec.bundled().get()
        let platformTools = try #require(spec.packages.first { $0.path == "platform-tools" })
        var files = installedFiles(spec)
        files.removeValue(forKey: packageXMLPath(platformTools))
        files[sdkRoot.appendingPathComponent(".mirage-provision.json").path] =
            "{\"\(platformTools.installPath)\":\"\(platformTools.revision)\"}"
        let result = check(spec: spec, files: files)
        #expect(result.missing.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test func unreadableInstalledVersionWarnsButKeepsExistingPackage() throws {
        let spec = try SdkSpec.bundled().get()
        let emulator = try #require(spec.packages.first { $0.path == "emulator" })
        var files = installedFiles(spec)
        files[packageXMLPath(emulator)] = "<localPackage><revision>"
        let result = check(spec: spec, files: files)
        #expect(result.missing.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].installedRevision == nil)
    }

    private func check(spec: SdkSpec, files: [String: String]) -> SetupCheckResult {
        SetupCheck.evaluate(
            spec: spec,
            sdkRoot: sdkRoot,
            avdDirectory: avdDirectory,
            fileExists: { files[$0.path] != nil },
            readFile: { url in
                if let value = files[url.path] { return value }
                throw TestReadError.missingFile
            })
    }

    private func installedFiles(
        _ spec: SdkSpec,
        revisions: [String: String] = [:],
        includeAvd: Bool = true
    ) -> [String: String] {
        let game = spec.avds.first { $0.name == "mirage-game" }
        let gameImageManifest = game?.imageManifest
        let packages = spec.packages.filter { package in
            package.path == "emulator" || package.path == "platform-tools"
                || gameImageManifest.map { package.manifestKey == $0 } == true
        }
        var files: [String: String] = [:]
        for package in packages {
            files[sdkRoot.appendingPathComponent(package.installPath, isDirectory: true).path] = ""
            let revision = revisions[package.installPath] ?? package.revision
            files[packageXMLPath(package)] = localPackageXML(revision)
        }
        if includeAvd {
            files[avdDirectory.appendingPathComponent("mirage-game.avd", isDirectory: true)
                .appendingPathComponent("config.ini", isDirectory: false).path] = ""
        }
        return files
    }

    private func packageXMLPath(_ package: SdkPackageSpec) -> String {
        sdkRoot.appendingPathComponent(package.installPath, isDirectory: true)
            .appendingPathComponent("package.xml", isDirectory: false).path
    }

    private func localPackageXML(_ revision: String) -> String {
        let parts = revision.split(separator: ".").map(String.init)
        let values = zip(["major", "minor", "micro"], parts).map { "<\($0.0)>\($0.1)</\($0.0)>" }.joined()
        return "<repository><localPackage path=\"test\"><revision>\(values)</revision></localPackage></repository>"
    }
}

private enum TestReadError: Error {
    case missingFile
}
