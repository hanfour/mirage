import MirageCore
import SwiftUI

struct ConnectionBanner: View {
    let state: ConnState

    var body: some View {
        switch state {
        case .connected:
            EmptyView()
        case .connecting:
            label("連線中…", .yellow)
        case .reconnecting(let n):
            label("重新連線中（第 \(n + 1) 次）…", .orange)
        case .disconnected:
            label("未連線", .red)
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.callout.bold())
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
            .padding(.top, 8)
    }
}
