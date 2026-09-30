import Foundation

public enum InsufficientDiskLogParser {
    public struct Space: Equatable, Sendable {
        public let availableMB: Double
        public let neededMB: Double

        public init(availableMB: Double, neededMB: Double) {
            self.availableMB = availableMB
            self.neededMB = neededMB
        }
    }

    public static func parse(_ text: String) -> Space? {
        guard let expression = try? NSRegularExpression(
            pattern: #"Not enough space to create userdata partition\. Available: ([0-9]+(?:\.[0-9]+)?) MB [^\r\n]*? need ([0-9]+(?:\.[0-9]+)?) MB\."#) else {
            return nil
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: fullRange),
              let availableRange = Range(match.range(at: 1), in: text),
              let neededRange = Range(match.range(at: 2), in: text),
              let availableMB = Double(text[availableRange]),
              let neededMB = Double(text[neededRange]) else {
            return nil
        }
        return Space(availableMB: availableMB, neededMB: neededMB)
    }
}
