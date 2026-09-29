import MirageCore
import SwiftUI

struct ConnectionBanner: View {
    let state: ConnState
    let instanceState: InstanceState?
    let avd: String
    let logURL: URL?
    let tableError: InstanceTableError?
    let specError: SdkSpecError?
    let onRestart: () -> Void
    let onShowLog: () -> Void

    var body: some View {
        if let tableError {
            instanceLabel(InstanceBanner.content(for: tableError))
        } else if let specError {
            instanceLabel(InstanceBanner.content(for: specError))
        } else if let content = InstanceBanner.content(for: instanceState, avd: avd) {
            instanceLabel(content)
        } else {
            connectionLabel
        }
    }

    @ViewBuilder
    private var connectionLabel: some View {
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

    private func instanceLabel(_ content: InstanceBanner.Content) -> some View {
        HStack(spacing: 10) {
            Text(content.text)
                .font(.callout.bold())
                .fixedSize(horizontal: false, vertical: true)
            if content.showsRestart {
                Button("重新啟動", action: onRestart)
                    .buttonStyle(.plain)
                    .font(.callout.bold())
                    .underline()
            }
            if content.showsLog, logURL != nil {
                Button("顯示記錄檔", action: onShowLog)
                    .buttonStyle(.plain)
                    .font(.callout.bold())
                    .underline()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(color(for: content.color).opacity(0.85), in: Capsule())
        .foregroundStyle(.black)
        .padding(.top, 8)
    }

    private func color(for category: InstanceBanner.ColorCategory) -> Color {
        switch category {
        case .progress: .yellow
        case .warning: .orange
        case .error: .red
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
