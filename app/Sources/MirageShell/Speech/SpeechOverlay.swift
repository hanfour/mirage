import SwiftUI

/// 語音辨識字幕。播放中逐字更新，播完保留最後一則，點一下複製到剪貼簿。
///
/// 放在畫面底部而不是頂部：`ConnectionBanner` 與 `InstallBanner` 已經佔了上方，
/// 而且字幕在下方比較接近一般播放器的習慣。`allowsHitTesting` 不能關掉，
/// 因為要點著複製；但只有在有文字時才佔位，沒文字時完全不擋觸控。
struct SpeechOverlay: View {
    let text: String
    let onCopy: (String) -> Void

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.title3)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .onTapGesture { onCopy(text) }
                .help("點一下複製這段文字")
        }
    }
}
