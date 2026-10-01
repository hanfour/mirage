import AppKit
import MirageCore

/// 既有 profile 編輯、儲存與遊戲偵測接線；由 AppModel 本體搬出，行為不變。
extension AppModel {
    /// 首次啟動時把內建範例 profile 種進使用者目錄。已存在者不動（見 `BuiltInProfiles.seed`）。
    ///
    /// 一定要印出結果：沒有這行，「內建 profile 到底有沒有到位」就變成只能靠翻檔案系統
    /// 才知道的事——而 D4 的本體正是「那個檔案從來沒到位，卻沒有任何訊號」。
    ///
    /// 無來源、已存在、複製成功與複製失敗分開回報，失敗逐筆附上原因。
    func seedBuiltInProfiles() {
        let sources = BuiltInProfiles.bundledSources()
        let outcome = BuiltInProfiles.seed(into: ProfileStore.standardDirectory(), from: sources)
        if sources.isEmpty {
            print("[profile] ⚠️ bundle 內找不到任何內建 profile：資源打包壞了")
        } else if outcome.copied.isEmpty && outcome.failed.isEmpty {
            print("[profile] 內建 profile 已存在（\(sources.count) 筆），未複製")
        }
        if !outcome.copied.isEmpty {
            print("[profile] 種下內建 profile：\(outcome.copied.joined(separator: ", "))")
        }
        for failure in outcome.failed {
            print("[profile] ⚠️ 內建 profile \(failure.name) 複製失敗：\(failure.error)")
        }
    }

    /// 建立 keymap controller。**啟動時不載入任何 profile**——載入哪一份由遊戲偵測決定
    /// （`applyActivation()` → `keymap?.reload(p)`）。
    ///
    /// 更正（2026-07-29，D4）：這裡原本用寫死的靜態欄位（值為 `com.example.game`）載入，
    /// 而那行的註解寫「尚未有偵測機制」——**那句話在 P1-d 就過期了**，`GameDetector` →
    /// `currentPackage` → `applyActivation` 早已是唯一的真實來源。舊路徑的實際效果是
    /// 「不管使用者在玩什麼，啟動時都載入 com.example.game 的 profile」。
    ///
    /// **行為改變**：沒有 adb 的環境下偵測不會跑（`AdbClient.standard()` 靜默不偵測），
    /// 因此不會有任何 profile。逃生出口是選單列的「套用 profile ▸」手動覆寫。
    /// 這是刻意的取捨——寧可沒有 profile，也不要載入一份與當前遊戲無關的。
    func loadKeymap() {
        keymap = KeymapController(queue: inputQueue, profile: nil)
        configureGamepadCapture()
        mouseCapture.updateCapture(shouldCapture: shouldCapture)
    }

    /// ⌘E：切換編輯模式。決策在 `EditorEntryDecider`（純函式、逐條測試），這裡只做副作用。
    ///
    /// **行為改變（2026-07-30，D5 階段 A）**：原本的 guard 是
    /// `guard editing || profile != nil else { return }`，而玩真實遊戲時 `profile` 永遠是 nil
    /// ——唯一的內建 profile 是佔位 gameId，載不到當前遊戲的檔——所以 ⌘E 完全沒有反應。
    /// 現在沒有 profile 時會用 starter 版面**在記憶體裡**建一份。
    ///
    /// **不落檔是刻意的**：檔案要按下「存檔」才出現。否則不小心按到 ⌘E 就會憑空生出一個檔案。
    func toggleEditing() {
        switch EditorEntryDecider.decide(editing: editing, profile: profile,
                                         currentPackage: currentPackage,
                                         starterBindings: starterBindings())
        {
        case .ignore:
            return
        case .leave:
            // 有未存變更就先問，**不要**先離開再問——離開的動作本身就把變更丟了。
            if editorSession?.isDirty == true {
                pendingLeaveConfirmation = true
                return
            }
            leaveEditing()
            return          // ← 必須 return：`leaveEditing()` 自己已經呼叫過
                            //   `setEditing` 與 `updateCapture`，落到 switch 尾端
                            //   會重複呼叫一次。兩者雖然冪等，但重複呼叫代表
                            //   「誰負責這件事」沒有單一答案，下一個人會改錯地方。
        case .enter(let p):
            // 即時套用：overlay 與引擎都看得到這份 profile。
            // 無條件 reload 是安全的：controller 此時尚未進入編輯模式，reload 會先
            // 釋放舊引擎的觸點與直通鍵再換引擎（D23，同時解決 D34(b)）。
            // 隨後 setEditing 會擋住編輯期間的 emit。
            profile = p
            keymap?.reload(p)
            editing = true
            editorSession = EditorSession(profile: p)
        }
        keymap?.setEditing(editing)
        mouseCapture.updateCapture(shouldCapture: shouldCapture)
    }

    /// Task 7（P1-c 終審 Important：游標陷阱）：是否該捕捉游標的統一判斷式，供
    /// `loadKeymap`/`toggleEditing`/`applyActivation` 共用，取代原本三處各自重複的
    /// 「有 profile 就 capture」判斷。額外收緊兩個條件：
    ///   - `NSApp.keyWindow != nil`——app 不在前景（被 alt-tab 切走、或背景啟動）時
    ///     不該捕捉，否則使用者會被系統級鎖住游標、只剩 ⌘E/quit 能逃脫。
    ///   - （ADAPTATION，見 task-7-report.md）brief 原文還要求 gate 在
    ///     「目前 profile 的 bindings 是否含 .look」——但這裡仍用 `keymap?.hasProfile`
    ///     而非 `profile != nil` 判斷，因為即使兩者現在同步（UPDATE，P1-d 終審
    ///     Important 已修正：`applyActivation()` 現在會把 `keymap?.reload(p)` 套用的
    ///     結果同步寫回 `profile`，見該函式），要正確算 look-only gating 仍得幫
    ///     KeymapController/KeymapEngine 新增「目前 engine 是否有 look binding」的
    ///     查詢，但本任務檔案範圍明確只列 MouseCapture.swift/AppModel.swift；比照
    ///     brief 明文允許的簡化版本，退回「有 profile 且非編輯且為 key window」，
    ///     不含 look 檢查（pending-human 記錄）。
    ///
    /// P1-e fast-follow：可見度由 `private` 放寬為 internal——`AppModel+Focus.swift` 的
    /// `didBecomeKey` 觀察者需要跨檔讀它（SE-0169：`private` 不跨檔），與
    /// `startAudio()`／`setupFullScreen()` 抽 extension 時同一個理由。
    var shouldCapture: Bool {
        // `NSApp` 的型別是 `NSApplication!`（IUO）：headless 測試行程若沒人先碰過
        // `NSApplication.shared`，它就是 nil，直接解包會讓整個 test run 帶著一句
        // 「Unexpectedly found nil」死掉，而那句錯誤訊息完全不指向「這是 NSApp」。
        // 先轉成 Optional 再用 `?.`，讓「App 不在前景／測試行程」與「有 key window」
        // 用同一條路徑表達，不必為前者另開特殊情況。
        keymap?.hasProfile == true && !textInput.usesText(hasProfile: true) && !editing && (NSApp as NSApplication?)?.keyWindow != nil
    }

    /// OverlayEditorView 的「存檔」呼叫這裡：version+1 已在編輯器裡算好，這裡只管原子寫
    /// 檔＋讓當前 session 的引擎立即套用新 binding。
    ///
    /// **回傳成功與否（2026-07-30，D5 階段 B 終審 I1）**：原本失敗只 `print` 一行就算了，
    /// 而呼叫端（`saveEditorSession`／`confirmLeaveSaving`）**不看結果**照樣清 `isDirty`、
    /// 照樣離開編輯——離開會 `applyActivation()` 從磁碟重讀，記憶體那份當場蒸發。使用者
    /// 拖了十分鐘、按了「存檔」、對話框關閉，變更全沒了，只有 console 一行。
    /// 這裡不擲例外是刻意的：呼叫端要的是「成不成」這個決策，不是錯誤本身。
    ///
    /// **走注入的 `store`，不是 `ProfileStore.standard()`（2026-07-30，D5 階段 A review 修正）**：
    /// 原本這裡自己另外呼叫 `.standard()`，跳過了 Task 5 開的注入縫——測試給的暫存
    /// `store` 只有讀（`applyActivation`/`startDetection`）接上，寫仍然打到使用者真實的
    /// `~/Library/Application Support/Mirage/profiles/`。`store` 的預設值就是 `.standard()`，
    /// 所以這裡改用注入的 `store` 對產品行為零改變，只是讓測試能攔到寫入。
    @discardableResult
    func saveProfile(_ p: KeymapProfile) -> Bool {
        do {
            try store.save(p)
            profileSaveError = nil
            profile = p
            keymap?.reload(p)
            if !editing { gamepadMonitor?.resynchronize() }
            return true
        } catch {
            print("[keymap] profile save failed: \(error)")
            profileSaveError = "無法儲存鍵位設定（\(p.gameId)）：\(error.localizedDescription)\n變更仍保留在編輯器中，排除問題後可再按存檔。"
            return false
        }
    }

    /// overlay 與抽屜共用的選取入口。兩邊都呼叫這裡，狀態因此只有一份。
    func selectBinding(_ id: UUID?) {
        editorSession = editorSession?.selecting(id)
    }

    func addTapBinding() {
        applyToSession { $0.addingTap(at: NormPoint(x: 0.5, y: 0.5)) }
    }

    func deleteSelectedBinding() {
        applyToSession { $0.deletingSelected() }
    }

    func beginRebindingSelectedBinding() {
        editorSession = editorSession?.beginningRebindSelected()
    }

    func clearSelectedGamepadBinding() {
        applyToSession { $0.clearingSelectedGamepadButton() }
    }

    /// 拖曳落點寫回 session 並**即時套用**到 `profile` 與引擎。
    ///
    /// 即時套用是設計文件定的存檔語意的前半（「即時套用＋明確存檔」）：畫面上的圈要跟著
    /// 手走，否則使用者要等到存檔才看得到結果。`emit` 在編輯模式下本來就被擋，所以套用到
    /// 引擎不會有任何東西送到 guest。
    func moveSelectedBinding(to p: NormPoint) {
        applyToSession { $0.movingSelected(to: p) }
    }

    /// 搖桿半徑。畫面上的橘方塊與抽屜的滑桿都走這裡——**同一個值，不是兩套設定**
    /// （設計文件 §4.3）。
    func setSelectedRadius(_ r: Double) {
        applyToSession { $0.settingSelectedRadius(r) }
    }

    /// 視角靈敏度。`.look` 在畫面上沒有標記，所以它只有抽屜這一個入口。
    func setSelectedSensitivity(_ s: Double) {
        applyToSession { $0.settingSelectedSensitivity(s) }
    }

    /// session 變換 → 同步 `profile` 與引擎。三個編輯入口（移動／半徑／靈敏度）共用它，
    /// 免得「改完忘了套用」在三個地方各犯一次。
    private func applyToSession(_ transform: (EditorSession) -> EditorSession) {
        guard let session = editorSession else { return }
        let updated = transform(session)
        guard updated != session else { return }
        editorSession = updated
        let p = updated.profile()
        profile = p
        keymap?.reload(p)
    }

    /// 抽屜「存檔」呼叫這裡。寫檔 → 引擎立即套用 → session 以存下的那份重建（`isDirty` 歸零）。
    ///
    /// **重建而不是只清旗標**：存完之後的「基準版本」已經變了（version+1），下一次存檔要
    /// 從新的基準再加一。用存下的 profile 重建 session 讓那件事自然成立，不必額外記帳。
    /// 代價是選取會被清掉——可接受，且比一份版本號對不上的 session 安全。
    func saveEditorSession() {
        guard let session = editorSession else { return }
        guard session.canSave else { return }
        let p = session.profile()
        // 寫檔失敗就**保持髒**（I1）：重建 session 會把 `isDirty` 歸零，而抽屜的存檔鍵
        // `.disabled(!session.isDirty)` 會跟著變灰——那是「已存好」的視覺訊號。使用者
        // 因此不會再按一次，變更就再也回不去了。
        guard saveProfile(p) else { return }
        editorSession = EditorSession(profile: p)
    }

    /// 離開編輯的唯一實作。三個出口與「沒有未存變更」那條路徑共用它。
    private func leaveEditing() {
        editing = false
        editorSession = nil
        // 離開編輯＝回到磁碟的真相（見 `toggleEditing` 的說明）。
        applyActivation()
        keymap?.setEditing(false)
        mouseCapture.updateCapture(shouldCapture: shouldCapture)
    }

    /// 提示的「存檔」：寫檔**成功**之後才離開。
    ///
    /// 存不成功就別離開（I1）——`leaveEditing()` 會 `applyActivation()` 從磁碟重讀，
    /// 變更當場蒸發。提示也刻意留著（`pendingLeaveConfirmation` 不清），使用者可以再按
    /// 一次「存檔」重試、或改選「捨棄」。判斷條件是 session 還髒不髒，而不是另記一個
    /// 「上次存檔成功嗎」的旗標——後者是同一件事的第二份真相。
    func confirmLeaveSaving() {
        saveEditorSession()
        guard editorSession?.isDirty != true else { return }
        pendingLeaveConfirmation = false
        leaveEditing()
    }

    /// 提示的「捨棄」：不寫檔直接離開。`leaveEditing()` 的 `applyActivation()` 會把
    /// 記憶體那份收掉、引擎清掉、游標放開——與 C1 修好的那條路徑同一條，不另開特例。
    func confirmLeaveDiscarding() {
        pendingLeaveConfirmation = false
        leaveEditing()
    }

    /// 提示的「繼續編輯」：什麼都不做，留在編輯模式。
    func cancelLeave() {
        pendingLeaveConfirmation = false
    }

    /// 啟動前景遊戲偵測（P1-d）。無 adb（找不到 SDK/非可執行檔）→ 靜默不偵測，維持
    /// 目前直接模式，對齊 spec 保守降級原則（同 loadKeymap 對「找不到 profile」的處理）。
    ///
    /// Task 6 偏離 brief 字面順序："尾綁" menuBar 回呼——這裡改成放在 adb guard 之前。
    /// 原因：手動覆蓋（停用 keymap／套用指定 profile）跟有沒有 adb 偵測是兩件事，沒有 adb
    /// 時使用者仍應該能從選單列手動套用 profile；若照原字面放在 guard 之後，無 adb 環境會
    /// 直接 return，選單列的三個回呼永遠不會被綁定，變成「有 bug 而不是設計」的特殊情況。
    func startDetection() {
        menuBar?.onDisable = { [weak self] in self?.setOverride(.disabled) }
        menuBar?.onAuto = { [weak self] in self?.setOverride(.auto) }
        menuBar?.onForce = { [weak self] gid in
            if let p = try? self?.store.load(gameId: gid) { self?.setOverride(.force(p)) }
        }
        guard let adb = AdbClient.standard() else { return }
        detector = GameDetector(adb: adb) { [weak self] pkg in
            self?.onForeground(pkg)
        }
        detector?.start()
    }

    /// GameDetector 回呼：前景 package 變動（含變成 nil）時重新跑一次啟用決策。
    private func onForeground(_ pkg: String?) {
        currentPackage = pkg
        applyActivation()
    }

    /// Task 6（選單列手動覆蓋 UI）呼叫：切換 auto/force/disabled 後立即重新決策。
    func setOverride(_ o: ManualOverride) {
        override = o
        applyActivation()
    }

    /// 純決策與 I/O 的接合點：load profile（I/O，失敗吞成 nil）→ ActivationDecider（純函式）
    /// →套用到 keymap engine →回報選單列。currentPackage 為 nil（無前景/adb 失敗）時
    /// loadedProfile 自然是 nil，ActivationDecider 在 .auto 下會決成 .inactive——不需要
    /// 額外的 nil 特例分支。
    ///
    /// **編輯中不得動 profile／引擎（2026-07-30，D5 階段 A 終審 I3）**：階段 A 之後
    /// 「記憶體限定的 profile」是主流路徑——使用者可能正在編一份從沒存過檔的 starter。
    /// 前景 package 一變動（或選單列按「恢復自動偵測」）就跑到這裡，若照常
    /// `keymap?.reload(...)` / `profile = ...`，會把使用者正在編的東西靜默換掉或清空，
    /// 而編輯器 UI（`if model.editing, let profile = model.profile`）會因為抓不到條件
    /// 整個消失，畫面上沒有任何提示也沒有可見出口。選單列與捕捉狀態仍然要更新，
    /// 那兩者是「這台 guest 現在是誰」的旁觀者，不是編輯中的資料本身。
    ///
    /// **讀的是呼叫當下的 `editing`**：`toggleEditing()` 的 `.leave` 分支會先把
    /// `editing` 設回 `false`、再呼叫這裡，所以離開編輯時這道 guard 不會擋到——那條路徑
    /// 本來就需要完整套用（回到磁碟的真相），這裡讀到的已經是 false。
    private func applyActivation() {
        guard !editing else {
            menuBar?.updateGame(package: currentPackage, active: keymap?.hasProfile == true)
            mouseCapture.updateCapture(shouldCapture: shouldCapture)
            return
        }
        let loaded: KeymapProfile? = currentPackage.flatMap { try? store.load(gameId: $0) }
        switch ActivationDecider.decide(loadedProfile: loaded, override: override) {
        // AUTHORIZED FIX（P1-d 終審 Important：⌘E 編輯器讀到 stale profile）：
        // 原本只呼叫 keymap?.reload(p) 套用到引擎，沒有同步寫回 `profile`——
        // ⌘E 的 OverlayEditorView 讀的是 `profile`，偵測切換遊戲後編輯器仍會顯示
        // 切換前（甚至啟動時）的舊 profile。這裡跟 saveProfile/loadKeymap 的既有
        // 慣例對齊：套用引擎的同時也寫回 `profile`，兩者永遠同步。
        case .active(let p): keymap?.reload(p); profile = p
        case .inactive:      keymap?.reload(nil); profile = nil
        }
        gamepadMonitor?.resynchronize()
        menuBar?.updateGame(package: currentPackage, active: keymap?.hasProfile == true)
        // Task 7：偵測切換 profile（含變成 .inactive）後，捕捉狀態也要跟著重新判斷——
        // 否則例如「原本無 profile 未捕捉，偵測到遊戲切成 active」的情況會漏掉 capture()。
        mouseCapture.updateCapture(shouldCapture: shouldCapture)
    }

}
