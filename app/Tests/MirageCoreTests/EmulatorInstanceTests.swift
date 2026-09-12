import Foundation
import Testing
@testable import MirageCore

@Suite("EmulatorDiscovery.listInstances")
struct EmulatorInstanceTests {
    /// 與 EmulatorDiscoveryTests.sample 同一份真實格式（37.1.11.0 的 pid_*.ini）。
    private let first = """
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
    private let second = """
        avd.id=mirage-poc
        port.serial=5556
        port.adb=5557
        avd.name=mirage-poc
        grpc.token=fake-second
        grpc.port=8556
        """

    private func file(_ pid: Int, text: String, modified: TimeInterval = 1)
        -> EmulatorDiscovery.DiscoveryFile {
        .init(name: "pid_\(pid).ini", text: text, modified: modified)
    }

    @Test func listsEveryLiveInstanceSortedByConsolePort() {
        let files = [file(200, text: second), file(100, text: first)]
        let got = EmulatorDiscovery.instances(files: files, isAlive: { _ in true })
        #expect(got == [
            EmulatorInstance(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554, pid: 100),
            EmulatorInstance(avdName: "mirage-poc", consolePort: 5556, grpcPort: 8556, pid: 200),
        ])
    }

    @Test func deadPIDIsDropped() {
        let files = [file(100, text: first), file(200, text: second)]
        let got = EmulatorDiscovery.instances(files: files, isAlive: { $0 != 200 })
        #expect(got.map(\.pid) == [100])
    }

    @Test(arguments: [
        "avd.name=x\ngrpc.port=8554",                      // 缺 port.serial
        "avd.name=x\nport.serial=5554",                    // 缺 grpc.port
        "port.serial=5554\ngrpc.port=8554",                // 缺 avd.name
        "avd.name=x\nport.serial=abc\ngrpc.port=8554",     // 埠不是整數
    ])
    func incompleteFileIsSkipped(text: String) {
        #expect(EmulatorDiscovery.instances(files: [file(1, text: text)], isAlive: { _ in true }).isEmpty)
    }

    @Test func invalidFilenameIsIgnored() {
        let bad = EmulatorDiscovery.DiscoveryFile(name: "other.ini", text: first, modified: 1)
        #expect(EmulatorDiscovery.instances(files: [bad], isAlive: { _ in true }).isEmpty)
    }

    /// 同一個 console 埠留下兩份探索檔（前一次崩潰沒清）：只留 modified 最新的那份。
    @Test func newestFileWinsForTheSameConsolePort() {
        let stale = file(100, text: first, modified: 1)
        let fresh = file(300, text: first, modified: 2)
        for order in [[stale, fresh], [fresh, stale]] {
            let got = EmulatorDiscovery.instances(files: order, isAlive: { _ in true })
            #expect(got.map(\.pid) == [300])
        }
    }

    @Test func livenessErrorYieldsNothing() {
        let got = EmulatorDiscovery.instances(files: [file(100, text: first)], isAlive: { _ in
            throw CocoaError(.fileReadUnknown)
        })
        #expect(got.isEmpty)
    }

    @Test func readErrorYieldsEmptyList() {
        let directory = URL(fileURLWithPath: "/fake/running")
        let got = EmulatorDiscovery.listInstances(directory: directory, isAlive: { _ in true },
                                                  readFiles: { url in
            #expect(url == directory)
            throw CocoaError(.fileNoSuchFile)
        })
        #expect(got.isEmpty)
    }

    @Test func injectedIOIsReadOnEveryCall() {
        let directory = URL(fileURLWithPath: "/fake/running")
        var current = [file(100, text: first)]
        let reader: (URL) throws -> [EmulatorDiscovery.DiscoveryFile] = { _ in current }
        #expect(EmulatorDiscovery.listInstances(directory: directory, isAlive: { _ in true },
                                                readFiles: reader).count == 1)
        current = [file(100, text: first), file(200, text: second)]
        #expect(EmulatorDiscovery.listInstances(directory: directory, isAlive: { _ in true },
                                                readFiles: reader).count == 2)
    }
}
