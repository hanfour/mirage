import Foundation

public struct Frame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgba: Data

    public init(width: Int, height: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public var isValid: Bool {
        width > 0 && height > 0 && rgba.count == width * height * 4
    }
}
