import Foundation

public protocol DisplayTransport: Sendable {
    func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error>
}

public enum TransportError: Error, Equatable {
    case unavailable(String)      // 可重連（UNAVAILABLE 等）
    case invalidRequest(String)   // fail fast，不重連
}
