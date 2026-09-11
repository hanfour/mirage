import Foundation
import CryptoKit
import Darwin

/// Opt-in JSONL, serialized at the source. Never stores clipboard/preedit plaintext.
public final class TextInputDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var sequence = 0
    private var failure: String?
    public var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    public init(path: String? = ProcessInfo.processInfo.environment["MIRAGE_IME_DIAGNOSTICS"]) {
        guard let path else { return }
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { failure = "Cannot create fresh IME diagnostic file (errno \(errno))"; return }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        record("diagnostics-start", ["schema": "1", "physicalInputAuthenticated": "false"])
    }
    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func record(_ event: String, _ fields: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        guard let handle, failure == nil else { return }
        sequence += 1
        var record: [String: Any] = fields
        record["event"] = event; record["seq"] = sequence
        record["time"] = Date().timeIntervalSince1970
        record["uptimeNS"] = DispatchTime.now().uptimeNanoseconds
        do {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(10)
            try handle.write(contentsOf: data)
        } catch { failure = "IME diagnostic write failed: \(error)" }
    }
}
