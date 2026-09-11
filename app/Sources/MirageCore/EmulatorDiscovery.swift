import Darwin
import Foundation

/// Emulator discovery is best-effort; only the RPC reports authentication failures.
public enum EmulatorDiscovery {
    struct DiscoveryFile {
        let name: String
        let text: String
        let modified: TimeInterval
    }

    static func parseINI(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            fields[key] = value
        }
        return fields
    }

    static func pid(from name: String) -> Int32? {
        guard name.hasPrefix("pid_"), name.hasSuffix(".ini") else { return nil }
        let digits = name.dropFirst(4).dropLast(4)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let pid = Int32(digits), pid > 0 else { return nil }
        return pid
    }

    /// Pure selection with a supplied liveness predicate; never fall back to an older token.
    static func selectToken(
        files: [DiscoveryFile], port: Int, isAlive: (Int32) throws -> Bool
    ) -> String? {
        do {
            var newest: DiscoveryFile?
            var newestFields: [String: String] = [:]
            for file in files {
                guard let pid = pid(from: file.name) else { continue }
                let fields = parseINI(file.text)
                guard fields["grpc.port"] == String(port), try isAlive(pid) else { continue }
                if let previous = newest,
                   previous.modified > file.modified ||
                    (previous.modified == file.modified && previous.name >= file.name) {
                    continue
                }
                newest = file
                newestFields = fields
            }
            guard let token = newestFields["grpc.token"], !token.isEmpty else { return nil }
            return token
        } catch {
            return nil
        }
    }

    static func pidIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let result = Darwin.kill(pid, 0)
        return processIsAlive(result: result, error: errno)
    }

    static func processIsAlive(result: Int32, error: Int32) -> Bool {
        result == 0 || error == EPERM
    }

    static var runningDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/TemporaryItems/avd/running", isDirectory: true)
    }

    static func readFiles(in directory: URL) throws -> [DiscoveryFile] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        return try urls.filter { pid(from: $0.lastPathComponent) != nil }.map { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modified = values.contentModificationDate else {
                throw CocoaError(.fileReadUnknown)
            }
            return DiscoveryFile(name: url.lastPathComponent, text: text,
                                 modified: modified.timeIntervalSince1970)
        }
    }

    static func discoverToken(
        port: Int, directory: URL = runningDirectory,
        isAlive: (Int32) throws -> Bool = pidIsAlive,
        readFiles: (URL) throws -> [DiscoveryFile] = EmulatorDiscovery.readFiles(in:)
    ) -> String? {
        do {
            return selectToken(files: try readFiles(directory), port: port, isAlive: isAlive)
        } catch {
            return nil
        }
    }

    /// Read afresh for each channel initialization; never cache a boot-specific token.
    public static func token(port: Int) -> String? {
        discoverToken(port: port)
    }
}
