import Foundation

private final class TransportOverrideWarning: @unchecked Sendable {
    private let lock = NSLock()
    private var didPrint = false

    func printOnce(_ message: String) {
        lock.lock()
        let shouldPrint = !didPrint
        didPrint = true
        lock.unlock()
        if shouldPrint { print(message) }
    }
}

private enum DisplayTransportLog {
    static let invalidOverride = TransportOverrideWarning()
}

/// 連線 reducer、健康探測與 channel / 串流操作；共用 EmulatorClient 的 actor 隔離。
extension EmulatorClient {
    // MARK: - 純轉移（reducer 語意不變，只發布狀態、回傳 effect）

    func step(_ event: ConnEvent) -> ConnEffect {
        let (next, effect) = ConnReducer.reduce(state, event)
        if connLog { print("[conn] \(state) --\(event)--> \(next)") }
        state = next
        stateCont.yield(next)
        return effect
    }

    // MARK: - 重連迴圈（非遞迴：消除 P1-a 終審 Minor #7 的 async frame 堆積）

    func runConnectionLoop() async {
        _ = step(.connectRequested)                 // → .connecting
        while running {
            let ready = ensureChannel()
            let result: HealthResult = ready ? await (probe?.probe(timeout: probeTimeout) ?? .failed) : .failed
            if connLog { print("[conn] ensureChannel=\(ready) probe=\(result)") }
            if !running { break }
            if case .healthy(let info) = result {
                emulatorVersion = info.version      // transport 選路用
                guestDisplay = info.display         // 觸控座標換算用
                makeDisplayTransport()
                _ = step(.connectSucceeded)         // → .connected（gate：只有健康才連上）
                startClipboardStream()
                await connectedRun()                // 阻塞到串流斷或 stop
                guard running else { break }
                await pump.detach()
                detachAudio()
                dropChannel()                       // 斷線先 drop 舊 channel（spec §4.1）
                let effect = step(.streamBroken)    // → .reconnecting(0)
                await backoffDelay(effect)
            } else {
                await pump.detach()
                detachAudio()
                dropChannel()                       // 探測失敗也 drop，下一圈重建
                let effect = step(.connectFailed)   // → .reconnecting(n)（attempt 由 reducer 遞增）
                await backoffDelay(effect)
            }
        }
    }

    /// 確保 channel/probe 存在；斷線後 channelBox 已被 dropChannel 清空，此處重建。
    ///
    /// **transport 刻意不在這裡建立**：要建哪種（MMAP 或 raw RGBA）取決於 emulator 版本，
    /// 而版本要等健康探測回報才知道。改由 makeDisplayTransport() 在探測成功後建立。
    private func ensureChannel() -> Bool {
        if channelBox == nil {
            do {
                let boxCh = try GrpcChannelBox(host: endpoint.host, port: endpoint.port)
                channelBox = boxCh
                probe = makeHealthProbe(boxCh)
                audioTransport = makeAudioTransport(boxCh)
            } catch {
                return false
            }
        }
        return probe != nil
    }

    /// 依探測回報的 emulator 版本與 `MIRAGE_TRANSPORT` 環境變數決定 display transport，
    /// 並印出選擇結果。
    ///
    /// 「該選哪一種」交給 `DisplayTransportSelector.choose(...)`（純函式，逐行單元測試
    /// 窮舉覆蓋，見 DisplayTransportSelectorTests）；這裡只剩下「讀環境變數 + 選出來之後
    /// 怎麼建構」，退化成一個純 switch，肉眼即可驗證，不需要再為了測選路而建真 channel。
    /// 環境變數在此讀取（而非傳給選擇器內部讀取）是刻意的：讓 `choose` 保持純函式、
    /// 可窮舉測試，副作用留在呼叫端。
    ///
    /// emulator 37 以上預設使用 MMAP 並用 FallbackTransport 包起來。`MIRAGE_TRANSPORT=raw`
    /// 可強制 raw；36.x 或版本未知一律只用 raw，避免舊 emulator 收到 MMAP 請求時崩潰。
    ///
    /// **執行緒安全前提**：`EmulatorClient` 是 actor，本方法與 `attachStream()`（唯一讀取
    /// `transport` 並呼叫 `frames()` 的地方）皆在 actor 隔離下序列執行——`transport` 不會
    /// 被並發讀寫，`frames()` 也不會被並發呼叫。`FallbackTransport.frames()` 內部「是否已
    /// 降級」的檢查在串流閉包外、非鎖保護，僅在「單一訂閱者」的使用契約下才無害；
    /// 若未來有呼叫端脫離這條 actor 序列，需要重新檢視那個檢查。
    private func makeDisplayTransport() {
        guard let boxCh = channelBox else { return }
        let transportOverride = ProcessInfo.processInfo.environment["MIRAGE_TRANSPORT"]
        if let transportOverride, transportOverride != "raw", transportOverride != "mmap" {
            DisplayTransportLog.invalidOverride.printOnce(
                "[transport] MIRAGE_TRANSPORT 值「\(transportOverride)」無效，忽略並使用預設"
            )
        }
        switch DisplayTransportSelector.choose(
            emulatorVersion: emulatorVersion,
            transportOverride: transportOverride
        ) {
        case .mmapWithRawFallback:
            transport = FallbackTransport(primary: makeMmapTransport(boxCh),
                                          secondary: makeTransport(boxCh))
            let selection = transportOverride == "mmap" ? "MIRAGE_TRANSPORT=mmap" : "預設"
            print("[transport] mmap（\(selection)，emulator \(emulatorVersion)；MIRAGE_TRANSPORT=raw 可改回）")
        case .rawOnly:
            transport = makeTransport(boxCh)
            let version = emulatorVersion.isEmpty ? "unknown" : emulatorVersion
            if transportOverride == "raw" {
                print("[transport] raw rgba（MIRAGE_TRANSPORT=raw，emulator \(version)）")
            } else {
                print("[transport] raw rgba（emulator \(version) 未達 MMAP 支援版本 37）")
            }
        }
    }

    /// connected 期間：掛串流並阻塞到第一個斷線訊號（或 stop）。setStreamSize 換源共用同一 breakCont。
    private func connectedRun() async {
        let (signal, cont) = AsyncStream<Void>.makeStream()
        breakCont = cont
        attachStream()
        attachAudio()
        for await _ in signal { break }
        breakCont = nil
    }

    func attachStream() {
        // 休眠期間不拉幀（即使底層重連）。防禦性 guard：目前碼庫中「休眠期間斷線觸發重連」
        // 這條路徑其實不可達——suspend() 呼叫 pump.detach() 後，FramePump 沒有存活的
        // consumer task，其 onEnd（唯一會 yield breakCont 的來源，見 signalBreak()）
        // 因此永不觸發，connectedRun() 會一直卡在 suspended 期間收不到斷線訊號。仍保留
        // 此 guard 作為未來重構的安全網。
        guard power != .suspended, power != .suspending else {
            if connLog { print("[conn] attachStream 略過：power=\(power)") }
            return
        }
        guard let transport, let box else {
            if connLog { print("[conn] attachStream 略過：transport=\(transport == nil ? "nil" : "有") box=\(box == nil ? "nil" : "有")") }
            return
        }
        if connLog { print("[conn] attachStream 掛上，請求 \(streamSize.w)x\(streamSize.h)") }
        let stream = transport.frames(width: streamSize.w, height: streamSize.h)
        Task {
            await pump.attach(stream, into: box) { [weak self] err in
                guard err != nil else { return }    // 換源正常結束不算斷
                Task { await self?.signalBreak() }
            }
        }
    }

    private func signalBreak() { breakCont?.yield() }

    /// 與 attachStream 對稱：休眠期間不掛載；無 sink（App 未接 AudioPlayer）時靜默不掛。
    func attachAudio() {
        guard power != .suspended, power != .suspending else { return }
        guard let audioTransport, let audioRing else { return }
        // 先卸再掛（呼叫 detachAudio 而非只 audioTask?.cancel()）：只取消 Swift Task
        // 中斷不了已 in-flight 的底層 gRPC next() ——guest 靜音時它會無限阻塞，若不顯式
        // cancelStream() 就疊上第二個訂閱，舊 call 會被孤兒化（Task 6 審查發現的缺口，
        // GrpcAudioTransport.packets() 已在 transport 層加了重入保護；這裡加第二層防禦）。
        detachAudio()
        // 終審 Minor 6（SPSC 單一生產者不變式，僅加註解不改碼）：AudioRingBuffer 是
        // SPSC（單生產者單消費者），但「單一生產者」在這裡是靠時序維持，不是靠結構
        // 保證——上面的 detachAudio() 只取消了「舊」Task（`audioTask?.cancel()`），
        // Swift 的 Task 取消是協作式的：舊 Task 內部 `for try await chunk in stream`
        // 迴圈要等下一次掛起點才會真正結束，理論上舊 Task 尾聲的 write() 可以跟下面
        // 新建 Task 第一次的 write() 在時間上重疊，讓兩個生產者同時寫同一個 ring。
        // 這在實務上不可達：舊 Task 停止寫入的時機是它自己的 gRPC stream 迭代器
        // 收到取消訊號那一刻（µs 等級的 CPU 排程延遲），而新 Task 第一次 write()
        // 之前必須先完成一次全新的 streamAudio RPC 往返（一次網路 RTT，數 ms 以上）；
        // 兩個時間尺度差了至少三個數量級，經驗上不會重疊。維持這個不變式不需要額外
        // 同步機制——但這是「靠時序」而非「靠結構」，值得對照它為何成立。
        let stream = audioTransport.packets(format: .standard)
        audioTask = Task { [audioRing] in
            do {
                for try await chunk in stream {
                    if Task.isCancelled { return }
                    audioRing.write(chunk.samples, rawByteCount: chunk.rawByteCount)
                }
            } catch {
                // 終審 Important 2：診斷訊號——若音訊 RPC 單獨失敗而連線本身仍健康
                // （health probe 不會因此觸發重連），少了這行音訊會永久靜默且沒有任何
                // 除錯線索（MIRAGE_AUDIO_LOG 只會印 pkt=0，跟 guest 本來就靜音無法區分）。
                // 刻意不在此自行重連——維持 spec 決策，重連只由畫面串流路徑驅動。
                print("[audio] stream ended: \(error)")
                // 串流斷屬正常（連線斷）；重連由既有連線迴圈負責，此處不自行重連。
                // 注意：**無封包 ≠ 斷線**——guest 靜音時本來就沒有封包，
                // 健康探測仍由 HealthProbe 獨佔負責。
            }
        }
    }

    /// 先取消 Swift Task，再顯式取消底層 RPC。後者不可省略：guest 靜音時
    /// streamAudio 會無限阻塞，Task.cancel() 中斷不了已 in-flight 的 next()。
    func detachAudio() {
        audioTask?.cancel()
        audioTask = nil
        audioTransport?.cancelStream()
    }

    // startClipboardStream() 搬到 EmulatorClient+Lifecycle.swift（終審 Minor 3：檔案行數約束）。

    private func backoffDelay(_ effect: ConnEffect) async {
        guard case .scheduleReconnect(let attempt) = effect, running else { return }
        let delay = backoff.delay(attempt: attempt, random: randomSource())
        try? await sleeper(delay)
    }

    // ADAPTATION (found during Task 5 verification, see task-5-report.md): the brief's
    // snippet appends `clipboardTask?.cancel(); clipboardTask = nil` AFTER `channelBox = nil`.
    // That order lets `channelBox`'s deinit (`group.syncShutdownGracefully()`) tear down the
    // NIO EventLoopGroup synchronously while the clipboard stream's in-flight promise on that
    // same group may still be unresolved — a real race that intermittently (~1-in-8 runs,
    // reproduced empirically) trips NIO's "leaking promise created" fatal precondition and
    // crashes the whole process. Cancelling `clipboardCall` (the real RPC, not just the Swift
    // Task — see startClipboardStream's ADAPTATION note above) BEFORE releasing the channel
    // resolves that promise synchronously up front, so the group's graceful shutdown has
    // nothing left dangling. dropChannel stays synchronous — no call-site changes needed.
    func dropChannel() {
        detachAudio()               // 必須在 channelBox = nil 之前：先解決 in-flight
                                     // promise，NIO group 才不會帶著未解決 promise 關閉
                                     // （P1-b 實證約 1/8 機率觸發 leaking promise 致命錯誤）
        audioTransport = nil
        clipboardCall?.cancel()
        clipboardTask?.cancel()
        clipboardTask = nil
        clipboardCall = nil
        // 顯示串流的顯式取消。音訊（detachAudio）與剪貼簿（clipboardCall?.cancel()）
        // 早就有這一步，唯獨顯示串流這條沒有——`pump.detach()` 只取消 Swift Task，
        // 而 Task 取消中斷不了已 in-flight 的 `next()`（見 DisplayTransport.cancelStream 的說明）。
        transport?.cancelStream()
        transport = nil
        probe = nil
        // 顯式、非阻塞地拆連線。舊碼靠 `channelBox = nil` 觸發 deinit 裡的**阻塞式**
        // syncShutdownGracefully()，而這裡跑在 cooperative 執行緒上——8 核就是 8 條，
        // 佔滿即全域死鎖（2026-07-29 實測 5 跑 3 卡）。shutdown() 冪等，之後的 deinit 是 no-op。
        channelBox?.shutdown()
        channelBox = nil
    }
}
