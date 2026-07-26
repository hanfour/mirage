import Foundation

/// APK 拖放安裝（Phase-1）：`.dropDestination` 觸發 `installAPKs(_:)`，逐檔呼叫 adb 安裝，
/// 結果經 `finish(_:gen:)` 進 `.finished` 並排程自動回 `.idle`。
///
/// 獨立成 extension 檔（比照 `AppModel+FullScreen.swift`／`AppModel+Audio.swift` 的既有前例，
/// 為 Task 8 review Important finding 的修正）：`MirageApp.swift` 本體職責過多，把這叢 APK
/// 安裝邏輯搬出來才是結構性改善，而非用刪空行湊行數。儲存屬性 `installState`／
/// `installGeneration` 留在 `MirageApp.swift`（Swift extension 不能宣告儲存屬性）。
///
/// 兩處存取層級調整（皆為 SE-0169 的直接後果——`private`/`private(set)` 只在同一檔案內的
/// extension 之間互通，跨檔案不適用）：
/// - `installState`/`installGeneration`：原本是 `private(set)`/`private`，搬出本檔後
///   `installAPKs(_:)`/`finish(_:gen:)` 需要跨檔讀寫，已在 `MirageApp.swift` 放寬成預設
///   internal（比照 `audioRing`/`audioPlayer` 的既有先例）。
/// - `finish(_:gen:)`：仍標 `private`——它只被本檔內的 `installAPKs(_:)` 呼叫，兩者現在同檔，
///   `private` 依然合法且更精確（不像 `startAudio()` 需要被 `MirageApp.swift` 的
///   `startLifecycle()` 跨檔呼叫，才被迫放寬成 internal）。
extension AppModel {
    /// 拖放安裝入口（Task 4 的 .dropDestination 呼叫，urls 已濾成 .apk）。
    /// adb 不可用 → 每個檔案記成明確 failure，不崩。安裝中再拖入直接忽略（MVP）。
    func installAPKs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        if case .installing = installState { return }   // 一次一批
        // 每批一開始就 bump generation（一批遞增一次）：新批次進來會再 bump，使前一批
        // 尚未觸發的自動消失 timer 的 gen 過時→no-op。這讓 token 真正守住其承諾——
        // 前批 stale timer 不會在「.finished 4s 窗內拖入的新批仍安裝中」時把狀態閃回 .idle
        //（終審 Minor：token 原本只在 finish 遞增，未涵蓋進入 .installing 的窗口）。
        installGeneration += 1
        let gen = installGeneration
        guard let adb = AdbClient.standard() else {
            finish(urls.map { InstallItem(name: $0.lastPathComponent, result: .failure("adb 不可用")) }, gen: gen)
            return
        }
        var items: [InstallItem] = []
        for (i, url) in urls.enumerated() {
            installState = .installing(done: i, total: urls.count)
            let r = await adb.install(apkURL: url)
            items.append(InstallItem(name: url.lastPathComponent, result: r))
        }
        finish(items, gen: gen)
    }

    /// 進 finished 並排程 ~4s 後自動回 idle。gen 為本批開始時取得的 generation；期間若有
    /// 新批次進來（會再 bump generation），此 timer 的 gen 已過時→no-op，不清新批次狀態。
    private func finish(_ items: [InstallItem], gen: Int) {
        installState = .finished(items)
        Task {   // @MainActor 繼承：以下讀寫皆在 MainActor，無資料競爭。
            try? await Task.sleep(for: .seconds(4))
            if self.installGeneration == gen { self.installState = .idle }
        }
    }
}
