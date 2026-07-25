import MirageCore
import SwiftUI

/// 安裝進度/結果 banner。仿 ConnectionBanner 樣式；置於畫面底部，不擋輸入。
/// import MirageCore：resultLabel 需 pattern-match InstallResult 的 .success/.failure。
struct InstallBanner: View {
    let state: InstallState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case let .installing(done, total):
            row {
                ProgressView().controlSize(.small).tint(.white)
                Text("安裝中… (\(min(done + 1, total))/\(total))").font(.callout.bold())
            }
        case let .finished(items):
            VStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    resultLabel(item)
                }
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func resultLabel(_ item: InstallItem) -> some View {
        switch item.result {
        case .success:
            capsule("✓ \(item.name) 安裝成功", .green)
        case let .failure(reason):
            capsule("✗ \(item.name)：\(reason)", .red)
        }
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.black.opacity(0.7), in: Capsule())
            .foregroundStyle(.white)
            .padding(.bottom, 12)
    }

    private func capsule(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.callout.bold())
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
    }
}
