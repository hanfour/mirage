import SwiftUI

struct TextInputControls: View {
    @Bindable var state: TextInputPresentation
    @State private var expanded = false
    var body: some View {
        Button(state.paused || state.localIssue != nil || state.policyError != nil ? "文字輸入：需檢查" : "文字輸入") { expanded.toggle() }
            .popover(isPresented: $expanded) {
                TextInputDetails(state: state)
            }
            .task {
                while !Task.isCancelled {
                    state.refresh()
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
    }
}

/// Shared by the actual popover and isolated failure-view evidence.
struct TextInputDetails: View {
    @Bindable var state: TextInputPresentation
    @State private var acknowledged = false
    var body: some View {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("輸入模式", selection: $state.mode) {
                        Text("自動（無映射時用 Mac 輸入法）").tag(TextInputPresentation.Mode.automatic)
                        Text("Mac 文字（暫停全部映射）").tag(TextInputPresentation.Mode.text)
                        Text("原始鍵位映射").tag(TextInputPresentation.Mode.keymap)
                    }
                    Text("已套用候選間隔：\(state.appliedSettle) ms")
                    TextField("下一筆候選間隔（毫秒）", text: $state.settle)
                    Button("套用至後續提交") { state.applyPolicy() }
                    Text("間隔不是消費確認，也沒有通用安全下限。文字模式 Return 不直送 guest；請用畫面上的送出鈕。")
                        .font(.caption)
                    if let issue = state.policyError ?? state.localIssue { Text(issue).foregroundStyle(.red) }
                    Button("暫停文字提交") { state.pause() }
                    Toggle("我已核對不確定的欄位結果", isOn: $acknowledged)
                    Button("手動恢復（不重送舊稿）") { state.resume(acknowledgingUncertainty: acknowledged); acknowledged = false }
                    if !state.localDraft.isEmpty { Button("複製本機草稿並暫停") { state.copyDraft(state.localDraft) } }
                    ScrollView {
                        ForEach(state.results.reversed(), id: \.commit.id) { result in
                            VStack(alignment: .leading) {
                                Text(TextInputPresentation.label(result.outcome))
                                Text(result.commit.text).textSelection(.enabled)
                                Button("複製這筆並暫停") { state.copyDraft(result.commit.text) }
                            }.padding(.vertical, 4)
                        }
                    }.frame(maxHeight: 220)
                }.padding().frame(width: 360)
    }
}
