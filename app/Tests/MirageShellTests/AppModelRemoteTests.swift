import Darwin
import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

/// 沒有幀時不建立 VT session。測試 encoder 注入只供錯誤回呼；socket、sink 與重啟皆是真的。
private final class RemoteModelEncoder: RemoteFrameEncoding, @unchecked Sendable {
    let fail: @Sendable (String) -> Void
    init(fail: @escaping @Sendable (String) -> Void) { self.fail = fail }
    func encode(_ frame: Frame, onAccessUnit: @escaping @Sendable (H264AccessUnit) -> Void) throws {}
    func requestKeyframe() {}
    func invalidate() {}
}

/// 在舊 listener 已關、新 listener 尚未 bind 的 factory 呼叫點占住埠，重現重新配對失敗。
private final class RemotePortBlocker {
    private var descriptor: Int32 = -1
    func listen(on port: Int) -> Bool {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0 && Darwin.listen(descriptor, 1) == 0
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppModelRemoteTests {
    private func withModel(_ tag: String, _ body: (AppModel) async throws -> Void) async throws {
        let (store, dir) = AppModelEditingTests.tempStore(tag)
        let suite = "MirageRemoteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(store: store, pairingTokens: PairingTokenStore(defaults: defaults, environment: [:]),
                             starterBindings: { [] })
        defer { try? FileManager.default.removeItem(at: dir) }
        model.remoteAddresses = { [HostAddress(interface: "en0", ip: "192.168.1.61")] }
        // 死埠避免 PM 的環境漏設 MIRAGE_PORT 時誤連真 guest。
        let changed = await model.client.setEndpoint(EmulatorEndpoint(host: "127.0.0.1", port: 1))
        #expect(changed)
        do {
            try await body(model)
        } catch {
            await model.disableRemote()
            await model.client.stop()
            throw error
        }
        await model.disableRemote()
        await model.client.stop()
    }

    @Test func repeatedEnableKeepsTokenAndExplicitRotationPersists() async throws {
        try await withModel("remote-persist") { model in
            await model.enableRemote(host: "127.0.0.1", port: 0)
            let first = try #require(model.remote?.token)
            await model.disableRemote()
            await model.enableRemote(host: "127.0.0.1", port: 0)
            #expect(model.remote?.token == first)
            await model.rotateRemoteToken()
            let rotated = try #require(model.remote?.token)
            #expect(rotated != first)
            if case .on(let urls, _, _) = model.remoteMenuState {
                #expect(urls.count == 1)
                #expect(urls.allSatisfy { $0.hasSuffix("/?t=\(rotated.value)") })
            } else { Issue.record("輪替後必須更新選單網址與 QR") }
            await model.disableRemote()
            await model.enableRemote(host: "127.0.0.1", port: 0)
            #expect(model.remote?.token == rotated)
        }
    }

    @Test func remoteOffUsesTheOriginalSink() async throws {
        try await withModel("remote-off") { model in
            #expect((model.activeSink as AnyObject) === (model.box as AnyObject))
            #expect((model.activeAudioSink as AnyObject) === model.audioRing)
            #expect(model.remote == nil)
            #expect(model.remoteMenuState == .off)
            #expect(!model.hasActiveRemoteViewer)
        }
    }

    @Test func enableWrapsBoxAndRestartsClientWithSameStreamSize() async throws {
        try await withModel("remote-enable") { model in
            await model.client.start(box: model.box, width: 900, height: 2000)
            await model.enableRemote(host: "127.0.0.1", port: 0)
            let sink = try #require(model.activeSink as? BroadcastFrameSink)
            #expect((sink.primary as AnyObject) === (model.box as AnyObject))
            let controller = try #require(model.remote)
            #expect(controller.secondary === sink.secondary)
            let audio = try #require(model.activeAudioSink as? BroadcastAudioSink)
            #expect((audio.primary as AnyObject) === model.audioRing)
            #expect(audio.secondary is RemoteAudioForwarder)
            let port = try #require(controller.boundPort)
            #expect(port > 0)
            if case .on(let urls, let addresses, let session) = model.remoteMenuState {
                #expect(session == .initial)
                #expect(addresses == model.remoteAddresses())
                #expect(urls.allSatisfy { $0.hasSuffix("/?t=\(controller.token.value)") })
            } else { Issue.record("預期 .on，實得 \(model.remoteMenuState)") }
            #expect(await model.client.isRunning)
            let size = await model.client.requestedStreamSize
            #expect(size.w == 900)
            #expect(size.h == 2000)
            await model.disableRemote()
            #expect((model.activeSink as AnyObject) === (model.box as AnyObject))
            #expect((model.activeAudioSink as AnyObject) === model.audioRing)
            #expect(model.remote == nil)
            #expect(model.remoteMenuState == .off)
            #expect(await model.client.isRunning)
        }
    }

    @Test func enableBeforeStartOnlySwapsSink() async throws {
        try await withModel("remote-before-start") { model in
            await model.enableRemote(host: "127.0.0.1", port: 0)
            #expect(model.activeSink is BroadcastFrameSink)
            #expect(!(await model.client.isRunning))
            await model.disableRemote()
            #expect((model.activeSink as AnyObject) === (model.box as AnyObject))
            #expect((model.activeAudioSink as AnyObject) === model.audioRing)
        }
    }

    @Test func disconnectRotatesTokenKeepingTheSinkAndHost() async throws {
        try await withModel("remote-disconnect") { model in
            let options = try #require(RemoteLaunchOptions.parse([
                "MIRAGE_REMOTE": "1", "MIRAGE_REMOTE_PULL_FPS": "20",
            ]))
            await model.enableRemote(host: "127.0.0.1", port: 0, pullInterval: options.pullInterval)
            let before = try #require(model.remote)
            let sinkBefore = model.activeSink as AnyObject
            let audioBefore = model.activeAudioSink as AnyObject
            await model.disconnectRemoteViewer()
            let after = try #require(model.remote)
            #expect(after !== before)
            #expect(after.token != before.token)
            #expect(after.secondary === before.secondary)
            #expect(after.host == "127.0.0.1")
            #expect(before.pullInterval == .milliseconds(50))
            #expect(after.pullInterval == before.pullInterval)
            #expect(after.boundPort == before.boundPort)
            #expect((model.activeSink as AnyObject) === sinkBefore)
            #expect((model.activeAudioSink as AnyObject) !== audioBefore)
            #expect(model.activeAudioSink is BroadcastAudioSink)
            #expect(!(await model.client.isRunning))
            let port = try #require(after.boundPort)
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/?t=\(before.token.value)"))
            let (_, response) = try await URLSession.shared.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 403)
        }
    }

    @Test func portInUseReportsFailureAndKeepsOriginalSink() async throws {
        try await withModel("remote-port-clash") { model in
            let occupant = RemoteServer(configuration: RemoteServerConfiguration(
                host: "127.0.0.1", port: 0, token: PairingToken.generate(), viewerPage: Data()), onTouches: { _ in })
            let port = try await occupant.start()
            await model.enableRemote(host: "127.0.0.1", port: port)
            #expect(model.remote == nil)
            #expect((model.activeSink as AnyObject) === (model.box as AnyObject))
            #expect((model.activeAudioSink as AnyObject) === model.audioRing)
            if case .failed(let message) = model.remoteMenuState {
                #expect(message.contains(String(port)))
            } else { Issue.record("預期 .failed，實得 \(model.remoteMenuState)") }
            await occupant.stop()
        }
    }

    @Test func failedRePairingRestoresOriginalSink() async throws {
        try await withModel("remote-repair-failure") { model in
            await model.enableRemote(host: "127.0.0.1", port: 0)
            let controller = try #require(model.remote)
            let port = try #require(controller.boundPort)
            let blocker = RemotePortBlocker()
            model.makeRemoteEncoder = { fail in
                #expect(blocker.listen(on: port))
                return RemoteModelEncoder(fail: fail)
            }
            await model.disconnectRemoteViewer()
            #expect(model.remote == nil)
            #expect((model.activeSink as AnyObject) === (model.box as AnyObject))
            #expect((model.activeAudioSink as AnyObject) === model.audioRing)
            if case .failed(let message) = model.remoteMenuState {
                #expect(message.contains(String(port)))
            } else { Issue.record("重新配對 bind 失敗必須回報錯誤") }
        }
    }

    @Test func errorDuringEnableIsNotLostByTransitionGuard() async throws {
        try await withModel("remote-early-error") { model in
            model.makeRemoteEncoder = { fail in
                fail("sessionCreation(-12903)")
                return RemoteModelEncoder(fail: fail)
            }
            await model.enableRemote(host: "127.0.0.1", port: 0)
            // 等整個 teardown 完成，不能只看到 remote = nil 就讀 sink。
            try await RemoteTestWaits.teardown(of: model)
            #expect(model.remoteMenuState == .failed("sessionCreation(-12903)"))
            #expect((model.activeSink as AnyObject) === (model.box as AnyObject))
            #expect((model.activeAudioSink as AnyObject) === model.audioRing)
        }
    }

    @Test func staleEncoderErrorCannotDisableNewPairing() async throws {
        try await withModel("remote-stale-error") { model in
            var encoders: [RemoteModelEncoder] = []
            model.makeRemoteEncoder = { fail in
                let encoder = RemoteModelEncoder(fail: fail)
                encoders.append(encoder)
                return encoder
            }
            await model.enableRemote(host: "127.0.0.1", port: 0)
            let old = try #require(encoders.first)
            await model.disconnectRemoteViewer()
            let current = try #require(encoders.last)
            #expect(current !== old)
            old.fail("stale")
            // 當代錯誤是處理回呼的正向見證；舊通知不得覆蓋當代訊息。
            current.fail("current")
            try await RemoteTestWaits.teardown(of: model)
            #expect(model.remoteMenuState == .failed("current"))
            #expect((model.activeSink as AnyObject) === (model.box as AnyObject))
            #expect((model.activeAudioSink as AnyObject) === model.audioRing)
        }
    }

    @Test func instanceSwitchKeepsBroadcastSink() async throws {
        try await withModel("remote-instance") { model in
            await model.enableRemote(host: "127.0.0.1", port: 0)
            let sink = model.activeSink as AnyObject
            let other = EmulatorInstance(avdName: "remote-test", consolePort: 5556, grpcPort: 2, pid: 2)
            await model.switchInstance(to: other)
            #expect((model.activeSink as AnyObject) === sink)
            #expect(model.remote != nil)
            #expect(await model.client.isRunning)
            #expect(await model.client.currentEndpoint.port == 2)
            await model.disableRemote()
            #expect((model.activeSink as AnyObject) === (model.box as AnyObject))
            #expect((model.activeAudioSink as AnyObject) === model.audioRing)
        }
    }
    @Test func teardownWaitHasAnIndependentDeadline() async throws {
        try await withModel("remote-teardown-timeout") { model in
            model.remoteTransitionInProgress = true
            defer { model.remoteTransitionInProgress = false }
            do {
                try await RemoteTestWaits.teardown(of: model, timeout: .milliseconds(20))
                Issue.record("未完成的 transition 必須逾時失敗")
            } catch let error as RemoteTestWaitError {
                if case .timedOut(let detail) = error {
                    #expect(detail.contains("AppModel teardown"))
                    #expect(detail.contains("transition=true"))
                } else { Issue.record("預期 teardown 逾時，實得 \(error)") }
            }
        }
    }

    @Test func viewerConnectionDrivesLifecycleGuard() async throws {
        try await withModel("remote-viewer") { model in
            await model.enableRemote(host: "127.0.0.1", port: 0)
            let controller = try #require(model.remote)
            let port = try #require(controller.boundPort)
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws/video?t=\(controller.token.value)"))
            #expect(!(await model.client.isRunning)) // listener 不依賴 emulator client.start。
            let probe = RemoteHandshakeProbe()
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            let session = URLSession(configuration: configuration, delegate: probe, delegateQueue: queue)
            defer { session.invalidateAndCancel() }
            let video = session.webSocketTask(with: url)
            let diagnostics: @Sendable () -> String = {
                "port=\(port)，state=\(controller.sessionState)，stats=\(controller.stats())"
            }
            defer { video.cancel(with: .normalClosure, reason: nil) }
            video.resume()
            try await probe.wait(diagnostics: diagnostics)
            let connected = try await RemoteTestWaits.state(in: controller.states, hasVideo: true,
                                                           diagnostics: diagnostics)
            #expect(connected.hasVideo)
            #expect(model.hasActiveRemoteViewer)
            video.cancel(with: .normalClosure, reason: nil)
            let disconnected = try await RemoteTestWaits.state(in: controller.states, hasVideo: false,
                                                              diagnostics: diagnostics)
            #expect(!disconnected.hasVideo)
            #expect(!model.hasActiveRemoteViewer)
        }
    }

    @Test func hiddenWindowSuspendsAfterViewerDisconnects() async throws {
        try await withModel("remote-hidden-disconnect") { model in
            let lifecycle = AppLifecycle(client: model.client, hasActiveRemoteViewer: { [weak model] in
                model?.hasActiveRemoteViewer ?? false
            })
            model.lifecycle = lifecycle
            await model.enableRemote(host: "127.0.0.1", port: 0)
            let controller = try #require(model.remote)
            let port = try #require(controller.boundPort)
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws/video?t=\(controller.token.value)"))
            #expect(!(await model.client.isRunning)) // listener 不依賴 emulator client.start。
            let probe = RemoteHandshakeProbe()
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            let session = URLSession(configuration: configuration, delegate: probe, delegateQueue: queue)
            defer { session.invalidateAndCancel() }
            let video = session.webSocketTask(with: url)
            let diagnostics: @Sendable () -> String = {
                "port=\(port)，state=\(controller.sessionState)，stats=\(controller.stats())"
            }
            defer { video.cancel(with: .normalClosure, reason: nil) }
            video.resume()
            try await probe.wait(diagnostics: diagnostics)
            let connected = try await RemoteTestWaits.state(in: controller.states, hasVideo: true,
                                                           diagnostics: diagnostics)
            #expect(connected.hasVideo)
            #expect(model.hasActiveRemoteViewer)
            lifecycle.didHideWindow() // windowShouldClose 呼叫的同一入口，不建立 NSWindow。
            #expect(lifecycle.isWindowHidden)
            #expect(await model.client.power == .active)
            video.cancel(with: .normalClosure, reason: nil)
            let disconnected = try await RemoteTestWaits.state(in: controller.states, hasVideo: false,
                                                              diagnostics: diagnostics)
            #expect(!disconnected.hasVideo)
            #expect(!model.hasActiveRemoteViewer)
            let powerStates = model.client.powerStates
            let power = try await RemoteTestWaits.withDeadline("隱藏視窗手機斷線後休眠") {
                for await state in powerStates {
                    if state == .suspended { return state }
                }
                try Task.checkCancellation()
                throw RemoteTestWaitError.ended("client.powerStates")
            }
            #expect(power == .suspended)
            #expect(await model.client.power == .suspended)
            // 同一 listener 重連：走 AppModel → lifecycle 的產品回呼，不直接呼叫 wake。
            let nextVideo = session.webSocketTask(with: url)
            defer { nextVideo.cancel(with: .normalClosure, reason: nil) }
            nextVideo.resume()
            let resumed = try await RemoteTestWaits.withDeadline("隱藏視窗手機重連後喚醒") {
                for await state in powerStates {
                    if state == .active { return state }
                }
                try Task.checkCancellation()
                throw RemoteTestWaitError.ended("client.powerStates")
            }
            #expect(resumed == .active)
            #expect(lifecycle.isWindowHidden)
            #expect(model.hasActiveRemoteViewer)
        }
    }

    @Test func remoteTextUsesExistingPolicyAndRetainsRejectedDraft() async throws {
        try await withModel("remote-text") { model in
            model.textInput.settle = "0"
            model.textInput.applyPolicy()
            await model.enableRemote(host: "127.0.0.1", port: 0)
            let controller = try #require(model.remote)
            let port = try #require(controller.boundPort)
            let base = "ws://127.0.0.1:\(port)"
            let videoURL = try #require(URL(string: "\(base)/ws/video?t=\(controller.token.value)"))
            let inputURL = try #require(URL(string: "\(base)/ws/input?t=\(controller.token.value)"))
            let video = URLSession.shared.webSocketTask(with: videoURL)
            defer { video.cancel(with: .normalClosure, reason: nil) }
            video.resume()
            _ = try await RemoteTestWaits.state(in: controller.states, hasVideo: true, diagnostics: {
                "remote text state=\(controller.sessionState)"
            })
            let input = URLSession.shared.webSocketTask(with: inputURL)
            defer { input.cancel(with: .normalClosure, reason: nil) }
            input.resume()
            try await input.send(.string(#"{"type":"text","text":"遠端草稿🙂","t":1}"#))
            try await input.send(.string(#"{"type":"ping","t":2}"#))
            _ = try await input.receive()
            await model.inputQueue.drained()
            let deadline = ContinuousClock.now + .seconds(2)
            while model.textInput.results.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let result = try #require(model.textInput.results.first)
            #expect(result.commit.text == "遠端草稿🙂")
            #expect(result.outcome == .rejected(.invalidPolicy("settle")))
        }
    }

    @Test func remoteConnectionStatusUsesEstablishedConnection() async throws {
        try await withModel("remote-connection-status") { model in
            model.connState = .connected
            #expect(model.emulatorConnected)
            model.connState = .connecting
            #expect(!model.emulatorConnected)
            model.connState = .disconnected
            #expect(!model.emulatorConnected)
        }
    }

}
