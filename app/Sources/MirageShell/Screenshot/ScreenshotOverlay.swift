import SwiftUI

struct ScreenshotNotice: Identifiable {
    let id = UUID()
    let text: String
}

struct ScreenshotOverlay: View {
    let notice: ScreenshotNotice?
    let onDismiss: (UUID) -> Void

    var body: some View {
        Group {
            if let notice {
                Text(notice.text)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 560)
                    .padding(.bottom, 104)
                    .task(id: notice.id) {
                        do {
                            try await Task.sleep(for: .seconds(2))
                        } catch {
                            return
                        }
                        onDismiss(notice.id)
                    }
            }
        }
    }
}
