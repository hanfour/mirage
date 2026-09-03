import Foundation
import GRPC
import MirageCore

public enum PullStatus: String, Codable, Equatable, Sendable {
    case measured
    case error
    case staticResult = "static"
    case stale

    public var exitCode: Int {
        switch self {
        case .measured: return 0
        case .error: return 1
        case .staticResult: return 2
        case .stale: return 3
        }
    }

    public static func resolve(frames: Int, distinct: Int, error: String?) -> PullStatus {
        if error != nil { return .error }
        if frames == 0 { return .staticResult }
        if distinct < 2 { return .stale }
        return .measured
    }
}

public struct PullResult: Encodable, Equatable, Sendable {
    public let status: PullStatus
    public let error: String?
    public let fps: Double
    public let frames: Int
    public let elapsed: Double
    public let width: Int
    public let height: Int
    public let transport: String
    public let distinct: Int
    public let client: String

    public init(
        status: PullStatus,
        error: String?,
        fps: Double,
        frames: Int,
        elapsed: Double,
        width: Int,
        height: Int,
        transport: String,
        distinct: Int,
        client: String
    ) {
        self.status = status
        self.error = error
        self.fps = fps
        self.frames = frames
        self.elapsed = elapsed
        self.width = width
        self.height = height
        self.transport = transport
        self.distinct = distinct
        self.client = client
    }

    public var exitCode: Int { status.exitCode }

    public func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public var textLine: String {
        var line = "fps=\(Self.format(fps, digits: 2)) frames=\(frames) "
            + "elapsed=\(Self.format(elapsed, digits: 2)) "
            + "size=\(width)x\(height) status=\(status.rawValue)"
        if let error {
            line += " error=\(error.replacingOccurrences(of: " ", with: "_"))"
        }
        line += " transport=\(transport) distinct=\(distinct) client=\(client)"
        return line
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case error
        case fps
        case frames
        case elapsed
        case width
        case height
        case transport
        case distinct
        case client
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status.rawValue, forKey: .status)
        if let error {
            try container.encode(error, forKey: .error)
        } else {
            try container.encodeNil(forKey: .error)
        }
        try container.encode(fps, forKey: .fps)
        try container.encode(frames, forKey: .frames)
        try container.encode(elapsed, forKey: .elapsed)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(transport, forKey: .transport)
        try container.encode(distinct, forKey: .distinct)
        try container.encode(client, forKey: .client)
    }

    private static func format(_ value: Double, digits: Int) -> String {
        String(
            format: "%.\(digits)f",
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: [value]
        )
    }
}

public enum PullEndpointError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let value): return "端點無效：\(value)"
        }
    }
}

public struct PullEndpoint: Sendable, Equatable {
    public let host: String
    public let port: Int

    public init(_ address: String) throws {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = value.lastIndex(of: ":"),
              separator != value.startIndex,
              separator != value.index(before: value.endIndex) else {
            throw PullEndpointError.invalid(address)
        }

        var host = String(value[..<separator])
        if host.first == "[", host.last == "]" {
            host.removeFirst()
            host.removeLast()
        }
        let portText = String(value[value.index(after: separator)...])
        guard !host.isEmpty, let port = Int(portText) else {
            throw PullEndpointError.invalid(address)
        }
        try self.init(host: host, port: port)
    }

    public init(host: String, port: Int) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty, (1...65_535).contains(port) else {
            throw PullEndpointError.invalid("\(host):\(port)")
        }
        self.host = normalizedHost
        self.port = port
    }
}

public enum MiragePull {
    public static let clientName = "grpc-swift"
    public static let transportName = "rgba"

    public static func fingerprint(of data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for index in stride(from: 0, to: data.count, by: 64) {
            hash ^= UInt64(data[index])
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    public static func measure(
        transport: any DisplayTransport,
        duration: Duration,
        width: Int,
        height: Int
    ) async -> PullResult {
        guard duration > .zero else {
            return invalidResult(
                message: "量測秒數必須大於 0",
                width: width,
                height: height
            )
        }
        guard width > 0, height > 0 else {
            return invalidResult(
                message: "畫面尺寸必須大於 0",
                width: width,
                height: height
            )
        }

        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: duration)
        let cancellation = StreamCancellation()
        let timeoutTask = Task { [transport] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            cancellation.cancelForTimeout(transport)
        }

        var frameCount = 0
        var fingerprints = Set<UInt64>()
        var failureMessage: String?

        do {
            for try await frame in transport.frames(width: width, height: height) {
                frameCount += 1
                fingerprints.insert(fingerprint(of: frame.rgba))
                if clock.now >= deadline {
                    cancellation.cancelForTimeout(transport)
                    break
                }
            }
        } catch {
            if !cancellation.didTimeout {
                failureMessage = message(for: error)
            }
        }

        timeoutTask.cancel()
        await timeoutTask.value
        if cancellation.didTimeout {
            failureMessage = nil
        }
        cancellation.cancelForCleanup(transport)

        let elapsed = seconds(from: started.duration(to: clock.now))
        let distinct = fingerprints.count
        let status = PullStatus.resolve(
            frames: frameCount,
            distinct: distinct,
            error: failureMessage
        )
        let fps = elapsed > 0 ? Double(frameCount) / elapsed : 0
        return PullResult(
            status: status,
            error: failureMessage,
            fps: fps,
            frames: frameCount,
            elapsed: elapsed,
            width: width,
            height: height,
            transport: transportName,
            distinct: distinct,
            client: clientName
        )
    }

    public static func run(
        endpoint: PullEndpoint,
        duration: Duration,
        width: Int,
        height: Int
    ) async -> PullResult {
        guard duration > .zero else {
            return invalidResult(
                message: "量測秒數必須大於 0",
                width: width,
                height: height
            )
        }
        guard width > 0, height > 0 else {
            return invalidResult(
                message: "畫面尺寸必須大於 0",
                width: width,
                height: height
            )
        }

        do {
            let channel = try GrpcChannelBox(host: endpoint.host, port: endpoint.port)
            let transport = GrpcStreamTransport(channel: channel)
            let result = await measure(
                transport: transport,
                duration: duration,
                width: width,
                height: height
            )
            channel.shutdown()
            try? await Task.sleep(for: .milliseconds(200))
            return result
        } catch {
            return invalidResult(
                message: message(for: error),
                width: width,
                height: height
            )
        }
    }

    private static func invalidResult(message: String, width: Int, height: Int) -> PullResult {
        PullResult(
            status: .error,
            error: message,
            fps: 0,
            frames: 0,
            elapsed: 0,
            width: width,
            height: height,
            transport: transportName,
            distinct: 0,
            client: clientName
        )
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func message(for error: Error) -> String {
        if let status = error as? GRPCStatus {
            let name = grpcCodeName(status.code)
            if let message = status.message, !message.isEmpty {
                return "\(name): \(message)"
            }
            if let cause = status.cause {
                return "\(name): \(cause)"
            }
            return name
        }

        if let transportError = error as? TransportError {
            switch transportError {
            case .unavailable(let message): return withMessage("UNAVAILABLE", message)
            case .invalidRequest(let message): return withMessage("INVALID_ARGUMENT", message)
            case .mmapUnusable(let message): return withMessage("MMAP_UNUSABLE", message)
            }
        }
        return String(describing: error)
    }

    private static func withMessage(_ name: String, _ message: String) -> String {
        message.isEmpty ? name : "\(name): \(message)"
    }

    private static func grpcCodeName(_ code: GRPCStatus.Code) -> String {
        switch code {
        case .ok: return "OK"
        case .cancelled: return "CANCELLED"
        case .unknown: return "UNKNOWN"
        case .invalidArgument: return "INVALID_ARGUMENT"
        case .deadlineExceeded: return "DEADLINE_EXCEEDED"
        case .notFound: return "NOT_FOUND"
        case .alreadyExists: return "ALREADY_EXISTS"
        case .permissionDenied: return "PERMISSION_DENIED"
        case .resourceExhausted: return "RESOURCE_EXHAUSTED"
        case .failedPrecondition: return "FAILED_PRECONDITION"
        case .aborted: return "ABORTED"
        case .outOfRange: return "OUT_OF_RANGE"
        case .unimplemented: return "UNIMPLEMENTED"
        case .internalError: return "INTERNAL"
        case .unavailable: return "UNAVAILABLE"
        case .dataLoss: return "DATA_LOSS"
        case .unauthenticated: return "UNAUTHENTICATED"
        default: return "UNKNOWN"
        }
    }
}

private final class StreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false

    var didTimeout: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func cancelForTimeout(_ transport: any DisplayTransport) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        timedOut = true
        lock.unlock()
        transport.cancelStream()
    }

    func cancelForCleanup(_ transport: any DisplayTransport) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        lock.unlock()
        transport.cancelStream()
    }
}
