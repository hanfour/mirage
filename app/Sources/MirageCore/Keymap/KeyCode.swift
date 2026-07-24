import Foundation

/// 觸發鍵：鍵盤（W3C key 值，直接餵 KeyboardEvent.key）或滑鼠鍵。
public enum KeyCode: Sendable, Codable, Equatable, Hashable {
    case key(String)          // 例："w"、"a"、"Shift"、" "（空白）
    case mouse(MouseButton)

    public enum MouseButton: String, Sendable, Codable, Equatable, Hashable {
        case left, right, middle
    }
}
