import Foundation

/// 探索檔裡一台活著的模擬器。三個值就是 emu.sh 的實例三元組，加上用來判活的 pid。
///
/// 純值型別、無 I/O。`selectToken` 只回答「這個 gRPC 埠的 token 是什麼」，這裡回答的是
/// 「現在有哪幾台」——同一份 `pid_*.ini`、同一組解析函式，只是不篩埠。
public struct EmulatorInstance: Sendable, Equatable, Hashable {
    public let avdName: String
    public let consolePort: Int
    public let grpcPort: Int
    public let pid: Int32

    public init(avdName: String, consolePort: Int, grpcPort: Int, pid: Int32) {
        self.avdName = avdName
        self.consolePort = consolePort
        self.grpcPort = grpcPort
        self.pid = pid
    }
}

extension EmulatorDiscovery {
    /// 純選擇：只留活著的、欄位齊全的；同一個 console 埠有多份檔時留 modified 最新的。
    /// 判活閉包拋錯 → 整份回空（與 `selectToken` 的 catch 語意一致：不猜）。
    static func instances(
        files: [DiscoveryFile], isAlive: (Int32) throws -> Bool
    ) -> [EmulatorInstance] {
        do {
            var newestByPort: [Int: (file: DiscoveryFile, instance: EmulatorInstance)] = [:]
            for file in files {
                guard let pid = pid(from: file.name) else { continue }
                let fields = parseINI(file.text)
                guard let avd = fields["avd.name"], !avd.isEmpty,
                      let console = fields["port.serial"].flatMap(Int.init),
                      let grpc = fields["grpc.port"].flatMap(Int.init),
                      try isAlive(pid) else { continue }
                let candidate = EmulatorInstance(avdName: avd, consolePort: console,
                                                 grpcPort: grpc, pid: pid)
                if let previous = newestByPort[console],
                   previous.file.modified > file.modified ||
                    (previous.file.modified == file.modified && previous.file.name >= file.name) {
                    continue
                }
                newestByPort[console] = (file, candidate)
            }
            return newestByPort.values.map(\.instance).sorted { $0.consolePort < $1.consolePort }
        } catch {
            return []
        }
    }

    /// I/O 可注入，簽章與 `discoverToken` 同形。讀不到目錄回空清單，不擲錯——
    /// 選單列拿空清單就顯示「沒有其他模擬器」，那正是使用者該看到的。
    static func listInstances(
        directory: URL = runningDirectory,
        isAlive: (Int32) throws -> Bool = pidIsAlive,
        readFiles: (URL) throws -> [DiscoveryFile] = EmulatorDiscovery.readFiles(in:)
    ) -> [EmulatorInstance] {
        do {
            return instances(files: try readFiles(directory), isAlive: isAlive)
        } catch {
            return []
        }
    }

    /// 每次呼叫重讀探索目錄；不快取，理由同 `token(port:)`。
    public static func instances() -> [EmulatorInstance] {
        listInstances()
    }
}
