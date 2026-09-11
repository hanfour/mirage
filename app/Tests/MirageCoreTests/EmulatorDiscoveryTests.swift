import Darwin
import Foundation
import GRPC
import Testing
@testable import MirageCore

@Suite("EmulatorDiscovery")
struct EmulatorDiscoveryTests {
    private let sample = """
        emulator.build=15917651
        avd.id=mirage-game
        emulator.version=37.1.11.0
        port.serial=5554
        port.adb=5555
        avd.name=mirage-game
        avd.dir=/example/.android/avd/mirage-game.avd
        cmdline="/example/qemu-system-aarch64" "-avd" "mirage-game" "-no-snapshot" "-port" "5554" "-grpc" "8554" "-grpc-use-token"
        grpc.token=fake-token=only
        launcher.dir=/example/emulator
        grpc.allowlist=/example/emulator/lib/emulator_access.json
        grpc.port=8554
        """

    private func file(_ pid: Int = 123, text: String? = nil, modified: TimeInterval = 1)
        -> EmulatorDiscovery.DiscoveryFile {
        .init(name: "pid_\(pid).ini", text: text ?? sample, modified: modified)
    }

    @Test func parsesRealFormatWithFakeToken() {
        let fields = EmulatorDiscovery.parseINI(sample)
        #expect(fields["grpc.port"] == "8554")
        #expect(fields["grpc.token"] == "fake-token=only")
        #expect(fields["cmdline"] == "\"/example/qemu-system-aarch64\" \"-avd\" \"mirage-game\" \"-no-snapshot\" \"-port\" \"5554\" \"-grpc\" \"8554\" \"-grpc-use-token\"")
        #expect(EmulatorDiscovery.parseINI("cmdline=\"arg=a b\"\nignored\n") ==
                ["cmdline": "\"arg=a b\""])
        #expect(EmulatorDiscovery.selectToken(files: [file()], port: 8554, isAlive: { _ in true })
                == "fake-token=only")
    }

    @Test(arguments: ["grpc.port=8554", "grpc.port=8554\ngrpc.token=", "grpc.port=8554\ngrpc.token=  "])
    func insecureOrEmptyToken(text: String) {
        #expect(EmulatorDiscovery.selectToken(files: [file(text: text)], port: 8554,
                                              isAlive: { _ in true }) == nil)
    }

    @Test func wrongPortDoesNotCheckLiveness() {
        var checked = false
        let token = EmulatorDiscovery.selectToken(files: [file()], port: 8556) { _ in
            checked = true
            return true
        }
        #expect(token == nil)
        #expect(!checked)
    }

    @Test func deadPIDIsIgnored() {
        #expect(EmulatorDiscovery.selectToken(files: [file()], port: 8554,
                                              isAlive: { _ in false }) == nil)
    }

    @Test func newestLiveMatchingInstanceWins() {
        let files = [file(1),
                     file(2, text: "grpc.port=8554\ngrpc.token=fake-new", modified: 2),
                     file(3, text: "grpc.port=8554\ngrpc.token=fake-dead", modified: 3),
                     file(4, text: "grpc.port=8556\ngrpc.token=fake-other", modified: 4)]
        for order in [files, Array(files.reversed())] {
            #expect(EmulatorDiscovery.selectToken(files: order, port: 8554,
                                                  isAlive: { $0 != 3 }) == "fake-new")
        }
    }

    @Test func newestInsecureInstanceDoesNotReuseOldToken() {
        #expect(EmulatorDiscovery.selectToken(
            files: [file(), file(124, text: "grpc.port=8554", modified: 2)], port: 8554,
            isAlive: { _ in true }) == nil)
    }

    @Test(arguments: ["pid_0.ini", "pid_-1.ini", "pid_bad.ini", "other.ini", "pid_99999999999999.ini"])
    func invalidFilenameIsIgnored(name: String) {
        #expect(EmulatorDiscovery.pid(from: name) == nil)
        #expect(EmulatorDiscovery.selectToken(
            files: [.init(name: name, text: sample, modified: 1)], port: 8554,
            isAlive: { _ in true }) == nil)
    }

    @Test(arguments: [CocoaError.Code.fileNoSuchFile, .fileReadNoPermission, .fileReadInapplicableStringEncoding])
    func directoryOrReadErrorsReturnNoToken(code: CocoaError.Code) {
        let directory = URL(fileURLWithPath: "/fake/running")
        let token = EmulatorDiscovery.discoverToken(
            port: 8554, directory: directory, isAlive: { _ in true }, readFiles: { url in
                #expect(url == directory)
                throw CocoaError(code)
            })
        #expect(token == nil)
    }

    @Test func injectedIORefreshesOnEveryDiscovery() {
        let directory = URL(fileURLWithPath: "/fake/running")
        var current = file()
        let reader: (URL) throws -> [EmulatorDiscovery.DiscoveryFile] = { url in
            #expect(url == directory)
            return [current]
        }
        #expect(EmulatorDiscovery.discoverToken(
            port: 8554, directory: directory, isAlive: { $0 == 123 }, readFiles: reader)
                == "fake-token=only")
        current = file(text: "grpc.port=8554\ngrpc.token=fake-reboot")
        #expect(EmulatorDiscovery.discoverToken(
            port: 8554, directory: directory, isAlive: { $0 == 123 }, readFiles: reader)
                == "fake-reboot")
    }

    @Test func authenticationMetadataPreservesExistingHeaders() {
        var existing = CallOptions()
        existing.customMetadata.add(name: "caller-key", value: "caller-value")
        let options = GrpcChannelBox.authenticatedOptions(token: "fake-header", options: existing)
        #expect(options.customMetadata["authorization"] == ["Bearer fake-header"])
        #expect(options.customMetadata["caller-key"] == ["caller-value"])
        #expect(existing.customMetadata["authorization"].isEmpty)
        #expect(GrpcChannelBox.authenticatedOptions(token: nil).customMetadata.isEmpty)
        #expect(GrpcChannelBox.authenticatedOptions(token: "").customMetadata.isEmpty)
    }

    @Test func killZeroSemantics() {
        #expect(EmulatorDiscovery.processIsAlive(result: 0, error: 0))
        #expect(EmulatorDiscovery.processIsAlive(result: -1, error: EPERM))
        #expect(!EmulatorDiscovery.processIsAlive(result: -1, error: ESRCH))
        #expect(!EmulatorDiscovery.processIsAlive(result: -1, error: EINVAL))
    }

    @Test func emptyDirectoryAndLivenessFailureReturnNoToken() {
        #expect(EmulatorDiscovery.discoverToken(
            port: 8554, directory: URL(fileURLWithPath: "/fake/running"),
            isAlive: { _ in true }, readFiles: { _ in [] }) == nil)
        #expect(EmulatorDiscovery.selectToken(files: [file()], port: 8554, isAlive: { _ in
            throw CocoaError(.fileReadUnknown)
        }) == nil)
    }
}
