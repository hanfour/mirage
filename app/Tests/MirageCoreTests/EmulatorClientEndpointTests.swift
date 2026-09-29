import Foundation
import Testing
@testable import MirageCore

/// 切換模擬器 = stop → setEndpoint → start。這裡守的是 actor 自己的三條不變式：
/// 端點只在停下來時可換、stop() 回來時舊迴圈已結束、串流尺寸跨越 stop/start 保留。
/// 端點都指向沒人監聽的埠（CI 的 MIRAGE_PORT 與保留埠 1），不需要模擬器。
@Suite(.timeLimit(.minutes(1))) struct EmulatorClientEndpointTests {
    private static let deadA = EmulatorEndpoint(host: "localhost", port: EmulatorClient.defaultEndpoint.port)
    private static let deadB = EmulatorEndpoint(host: "localhost", port: 1)

    /// 版本 <37（見 ScriptedProbe 的說明）：走 makeTransport 的假件，不建真的 MMAP transport。
    private func makeClient() -> EmulatorClient {
        EmulatorClient(host: Self.deadA.host, port: Self.deadA.port,
                       makeTransport: { _ in MockTransport([.yieldThenHang(1)]) },
                       makeHealthProbe: { _ in ScriptedProbe([]) },
                       sleeper: { _ in }, randomSource: { 0.5 })
    }

    @Test func initialEndpointComesFromInit() async {
        let client = makeClient()
        #expect(await client.currentEndpoint == Self.deadA)
        #expect(!(await client.isRunning))
    }

    @Test func setEndpointWhileStoppedChangesTarget() async {
        let client = makeClient()
        #expect(await client.setEndpoint(Self.deadB))
        #expect(await client.currentEndpoint == Self.deadB)
    }

    /// 在跑的時候換端點會讓「狀態說已切換、畫面還是舊那台」——必須拒絕，且不改。
    @Test func setEndpointWhileRunningIsRefusedUntilStopped() async {
        let client = makeClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        #expect(await client.isRunning)
        #expect(!(await client.setEndpoint(Self.deadB)))
        #expect(await client.currentEndpoint == Self.deadA)

        await client.stop()
        #expect(!(await client.isRunning))
        #expect(await client.setEndpoint(Self.deadB))
        #expect(await client.currentEndpoint == Self.deadB)
    }

    /// 切換後重新 start 要沿用最後一次要求的尺寸——全螢幕下 MirrorView 已把尺寸換成
    /// 內容矩形，退回 540x1200 會讓畫面糊掉且沒有訊號（resize 事件不會再來一次）。
    @Test func requestedStreamSizeSurvivesStop() async {
        let client = makeClient()
        await client.start(box: LatestFrameBox(), width: 900, height: 2000)
        await client.setStreamSize(width: 1080, height: 1800)
        await client.stop()
        let size = await client.requestedStreamSize
        #expect(size.w == 1080)
        #expect(size.h == 1800)
    }

    /// 設計決定 2：stop() 回來時舊迴圈必須已結束。
    ///
    /// 閘門確認已進入 sleeper，再取消。取消後由獨立 Task 延後 50ms 完成清理，
    /// 避免 Thread.sleep 阻塞 cooperative executor；stop 返回時必須已完成清理。
    @Test func stopWaitsForTheOldLoopToFinish() async throws {
        let entered = CountGate()
        let ended = CountGate()
        let client = EmulatorClient(
            host: Self.deadA.host, port: Self.deadA.port,
            makeTransport: { _ in MockTransport([]) },
            makeHealthProbe: { _ in ScriptedProbe(Array(repeating: .failed, count: 1000)) },
            sleeper: { _ in
                entered.increment()
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
                    ended.increment()
                    throw error
                }
            },
            randomSource: { 0.5 })
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        await entered.wait(for: 1)
        await client.stop()
        #expect(ended.current == 1)
        #expect(!(await client.isRunning))
    }

    /// stop() 之後 client 不知道任何 guest 的事；下一台的解析度要等它自己的探測。
    @Test func stopForgetsGuestDisplay() async throws {
        let probe = ScriptedProbe([.healthy(EmulatorInfo(
            version: "36.6.11.0", display: (w: 1080, h: 2400), booted: true))])
        let mock = MockTransport([.yieldThenHang(1)])
        let client = EmulatorClient(host: Self.deadA.host, port: Self.deadA.port,
                                    makeTransport: { _ in mock },
                                    makeHealthProbe: { _ in probe },
                                    sleeper: { _ in }, randomSource: { 0.5 })
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        await mock.subscribeGate.wait(for: 1)
        let before = await client.displaySize
        #expect(before?.w == 1080)
        await client.stop()
        #expect(await client.displaySize == nil)
    }

    /// stop 等 sleeper 清理時 actor 可重入；此時不能換端點或偷開第二條迴圈。
    @Test func stoppingRejectsRestartAndEndpointChange() async {
        let entered = CountGate()
        let cancelled = CountGate()
        let release = CountGate()
        let ended = CountGate()
        let client = EmulatorClient(
            host: Self.deadA.host, port: Self.deadA.port,
            makeTransport: { _ in MockTransport([]) },
            makeHealthProbe: { _ in ScriptedProbe([.failed]) },
            sleeper: { _ in
                entered.increment()
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    cancelled.increment()
                    await release.wait(for: 1)
                    ended.increment()
                    throw error
                }
            })
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        await entered.wait(for: 1)
        let stopping = Task { await client.stop() }
        await cancelled.wait(for: 1)
        #expect(!(await client.setEndpoint(Self.deadB)))
        await client.start(box: LatestFrameBox(), width: 900, height: 2000)
        #expect(!(await client.isRunning))
        #expect(await client.currentEndpoint == Self.deadA)
        let size = await client.requestedStreamSize
        #expect(size.w == 540)
        #expect(size.h == 1200)
        let repeatedStop = Task { await client.stop() }
        release.increment()
        await stopping.value
        await repeatedStop.value
        #expect(ended.current == 1)
        #expect(await client.setEndpoint(Self.deadB))
        await client.start(box: LatestFrameBox(), width: 900, height: 2000)
        #expect(await client.isRunning)
        await client.stop()
    }

}
