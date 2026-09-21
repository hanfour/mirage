import AppKit
import MirageCore

/// 注入點只替換系統編碼器；server、sink 切換與錯誤復原仍走產品路徑。
typealias RemoteEncoderFactory = (
    @escaping @Sendable (String) -> Void
) -> any RemoteFrameEncoding

/// 手機遙控的開關、配對狀態與 sink 生命週期。所有轉移在 MainActor 串列化，
/// callback 另帶 generation，舊 server 的非同步通知不能污染新的一次配對。
extension AppModel {
    var emulatorConnected: Bool { connState == .connected }

    var hasActiveRemoteViewer: Bool { remote?.sessionState.isViewerConnected ?? false }

    func setupRemoteMenu() {
        menuBar?.remoteEntries = { [weak self] in
            RemoteMenu.entries(self?.remoteMenuState ?? .off,
                               pullInterval: self?.remote?.pullInterval ?? .nanoseconds(1_000_000_000 / 30),
                               clientStats: self?.remote?.latestClientStats,
                               canRotateToken: self?.pairingTokens.override == nil)
        }
        menuBar?.onToggleRemote = { [weak self] in Task { @MainActor in await self?.toggleRemote() } }
        menuBar?.onDisconnectRemote = { [weak self] in Task { @MainActor in await self?.disconnectRemoteViewer() } }
        menuBar?.onRotateRemoteToken = { [weak self] in Task { @MainActor in await self?.rotateRemoteToken() } }
        menuBar?.onCopyRemoteURL = { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        }
    }

    func toggleRemote() async {
        if remote == nil { await enableRemote() } else { await disableRemote() }
    }

    /// server 綁定成功才換 sink；啟動前開啟只換 activeSink，不自行啟動 client。
    func enableRemote(host: String = RemoteServerConfiguration.allInterfaces,
                      port: Int = RemoteServerConfiguration.defaultPort,
                      token: PairingToken? = nil,
                      pullInterval: Duration = .nanoseconds(1_000_000_000 / 30)) async
    {
        guard remote == nil, !remoteTransitionInProgress else { return }
        remoteTransitionInProgress = true
        defer { finishRemoteTransition() }
        await startRemote(host: host, port: port, token: pairingTokens.override ?? token ?? pairingTokens.token(), pullInterval: pullInterval)
    }

    /// 關閉後 activeSink 必須是 FrameSinkFactory.make 的原物件，沒有扇出包裝。
    func disableRemote() async {
        guard !remoteTransitionInProgress else { return }
        remoteTransitionInProgress = true
        defer { finishRemoteTransition() }
        await stopRemote()
        remoteMenuState = .off
    }

    /// 重新配對保留 secondary、activeSink、host 與 port，換 token 並撤銷舊連線。
    /// 失敗則完整退回 off 的幀路徑，不留下無人讀取的 BroadcastFrameSink。
    func disconnectRemoteViewer() async {
        guard let controller = remote, !remoteTransitionInProgress else { return }
        remoteTransitionInProgress = true
        defer { finishRemoteTransition() }
        let port = controller.boundPort ?? RemoteServerConfiguration.defaultPort
        remoteGeneration = UUID()
        remotePendingError = nil
        remote = nil
        await controller.stop()
        await inputQueue.drained()
        // 換配對等於換遠端工作階段：舊 viewer 排好但還沒送出的文字不能貼進新的一次連線。
        inputQueue.invalidateRemoteTextSession()
        _ = controller.secondary.takeLatest() // 新配對不要送出停服前的殘留幀。
        await startRemote(host: controller.host, port: port, token: pairingTokens.token(rotate: true),
                          pullInterval: controller.pullInterval)
        if !hasActiveRemoteViewer { lifecycle?.remoteViewerDisconnected() }
    }

    func rotateRemoteToken() async {
        guard pairingTokens.override == nil else { return }
        await disconnectRemoteViewer()
    }

    // MARK: - 轉移內部（呼叫者持有 remoteTransitionInProgress）

    private func startRemote(host: String, port: Int, token: PairingToken, pullInterval: Duration) async {
        remoteGeneration = UUID()
        remotePendingError = nil
        guard let page = RemoteViewerPage.bundled() else {
            remoteAudioForwarder = nil
            await switchSink(to: box, audio: currentAudioSink())
            remoteMenuState = .failed("找不到 viewer.html")
            return
        }
        let secondary = (activeSink as? BroadcastFrameSink)?.secondary ?? LatestFrameBox()
        let controller = makeRemoteController(host: host, port: port, token: token,
                                              page: page, secondary: secondary, pullInterval: pullInterval)
        do {
            let bound = try await controller.start()
            remote = controller
            let addresses = remoteAddresses()
            let urls = RemoteURL.all(addresses: addresses, port: bound, token: controller.token)
            remoteMenuState = .on(urls: urls, addresses: addresses, session: controller.sessionState)
            print("[remote] listening port=\(bound) 已可連線")
        } catch {
            remoteGeneration = UUID()
            await controller.stop()
            await inputQueue.drained()
            remoteAudioForwarder = nil
            await switchSink(to: box, audio: currentAudioSink())
            remoteMenuState = .failed("埠 \(port) 無法監聽：\(error)")
            print("[remote] 啟動失敗 port=\(port)：\(error)")
            return
        }
        let frameSink = (activeSink as? BroadcastFrameSink)
            ?? BroadcastFrameSink(primary: box, secondary: secondary)
        remoteAudioForwarder = RemoteAudioForwarder(controller: controller)
        await switchSink(to: frameSink, audio: currentAudioSink())
    }

    private func stopRemote() async {
        let controller = remote
        remoteGeneration = UUID()
        remotePendingError = nil
        remote = nil
        if let controller { await controller.stop() }
        // server.stop 發出的 release 必須在重啟 emulator 連線前送完。
        await inputQueue.drained()
        inputQueue.invalidateRemoteTextSession()
        remoteAudioForwarder = nil
        await switchSink(to: box, audio: currentAudioSink())
        // generation 已換，server 關閉時送出的 nil 會被擋掉，這裡自己清。
        await updateRemoteViewport(nil)
        lifecycle?.remoteViewerDisconnected()
    }

    private func makeRemoteController(host: String, port: Int, token: PairingToken, page: Data,
                                      secondary: LatestFrameBox, pullInterval: Duration) -> RemoteMirrorController
    {
        var configuration = RemoteMirrorConfiguration(token: token, viewerPage: page)
        configuration.host = host
        configuration.port = port
        configuration.pullInterval = pullInterval
        let generation = remoteGeneration
        let fail: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in await self?.failRemote(message, generation: generation) }
        }
        return RemoteMirrorController(
            configuration: configuration, secondary: secondary, inputQueue: inputQueue,
            makeEncoder: { makeRemoteEncoder(fail) },
            emulatorConnected: { [weak self] in await self?.emulatorConnected ?? false },
            onText: { [textInput] text in textInput.enqueue(text, origin: "remote") },
            onViewport: { [weak self] viewport in
                Task { @MainActor in
                    guard let self, generation == self.remoteGeneration else { return }
                    await self.updateRemoteViewport(viewport)
                }
            },
            onError: fail,
            onStateChanged: { [weak self] _ in
                Task { @MainActor in self?.remoteSessionChanged(generation: generation) }
            })
    }

    /// 硬體建立／提交／回呼失敗均關閉功能。轉移中暫存，不能被 disable 的重入 guard 吃掉。
    private func failRemote(_ message: String, generation: UUID) async {
        guard generation == remoteGeneration else { return }
        if remoteTransitionInProgress {
            remotePendingError = message
            return
        }
        remoteTransitionInProgress = true
        defer { finishRemoteTransition() }
        print("[remote] \(message)，功能關閉")
        await stopRemote()
        remoteMenuState = .failed(message)
    }

    private func finishRemoteTransition() {
        remoteTransitionInProgress = false
        if let message = remotePendingError {
            remotePendingError = nil
            let generation = remoteGeneration
            Task { @MainActor in await failRemote(message, generation: generation) }
        }
    }

    private func remoteSessionChanged(generation: UUID) {
        guard generation == remoteGeneration, let remote,
              case .on(let urls, let addresses, let previous) = remoteMenuState else { return }
        // Task 投遞順序未必等於 server callback 順序，因此讀目前快照。
        let state = remote.sessionState
        remoteMenuState = .on(urls: urls, addresses: addresses, session: state)
        if state.hasVideo, !previous.hasVideo {
            Task { @MainActor [weak self] in
                guard let self, generation == self.remoteGeneration, remote.sessionState.hasVideo else { return }
                await self.lifecycle?.remoteViewerConnected()
                guard generation == self.remoteGeneration, remote.sessionState.hasVideo else { return }
                remote.requestKeyframe()
            }
        }
        // 通常是 true → false；若 MainActor 合併了快速開關的通知，隱藏狀態仍可補休眠。
        if !state.hasVideo, previous.hasVideo || lifecycle?.isWindowHidden == true {
            lifecycle?.remoteViewerDisconnected()
        }
    }

    /// 與模擬器切換共用任務鏈。等前一個 stop/start 完成後才看 isRunning，
    /// 否則正好撞到 stop 的短暫 false 會漏掉換 sink 後的重新啟動。
    private func switchSink(to sink: any FrameSink, audio: any AudioSink) async {
        let frameChanged = (activeSink as AnyObject) !== (sink as AnyObject)
        activeSink = sink
        activeAudioSink = audio
        let previous = instanceSwitchTask
        let task = Task { @MainActor in
            await previous?.value
            // 重新配對可能沿用畫面 sink，但音訊必須改綁新的 controller。
            await self.client.setAudioSink(audio)
            guard frameChanged, await self.client.isRunning else { return }
            let size = await self.client.requestedStreamSize
            await self.client.stop()
            await self.client.start(box: self.activeSink, width: size.w, height: size.h)
        }
        instanceSwitchTask = task
        await task.value
    }
}
