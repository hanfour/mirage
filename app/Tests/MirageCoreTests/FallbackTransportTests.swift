import Foundation
import Testing
@testable import MirageCore

/// 可腳本化的假 transport：記錄訂閱次數，依劇本送幀或丟指定錯誤。
private final class ScriptedTransport: DisplayTransport, @unchecked Sendable {
    enum Script {
        case frames([UInt8])            // 依序送出這些 tag 的幀後結束
        case framesThenError([UInt8], Error)
        case error(Error)               // 立刻丟錯，不送幀
        case framesThenHang([UInt8])    // 送完幀後不結束（模擬健康串流）
    }
    private let lock = NSLock()
    private var scripts: [Script]
    private var _subscribeCount = 0

    init(_ scripts: [Script]) { self.scripts = scripts }
    var subscribeCount: Int { lock.lock(); defer { lock.unlock() }; return _subscribeCount }

    func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        lock.lock()
        _subscribeCount += 1
        let script = scripts.isEmpty ? .framesThenHang([]) : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { cont in
            func emit(_ tags: [UInt8]) {
                for t in tags { cont.yield(Frame(width: 1, height: 1, rgba: Data([t, 0, 0, 0]))) }
            }
            switch script {
            case .frames(let tags): emit(tags); cont.finish()
            case .framesThenError(let tags, let err): emit(tags); cont.finish(throwing: err)
            case .error(let err): cont.finish(throwing: err)
            case .framesThenHang(let tags): emit(tags)      // 不 finish
            }
        }
    }
}

private func collect(_ stream: AsyncThrowingStream<Frame, Error>,
                     max: Int) async -> (tags: [UInt8], error: Error?) {
    var tags: [UInt8] = []
    do {
        for try await f in stream {
            tags.append(f.rgba.first ?? 0)
            if tags.count >= max { break }
        }
        return (tags, nil)
    } catch {
        return (tags, error)
    }
}

@Suite struct FallbackTransportTests {
    /// 1. primary 正常 → 全程不切換，secondary 從未被訂閱。
    @Test func healthyPrimaryNeverTouchesSecondary() async {
        let primary = ScriptedTransport([.frames([1, 2, 3])])
        let secondary = ScriptedTransport([.frames([9])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        let (tags, err) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [1, 2, 3])
        #expect(err == nil)
        #expect(secondary.subscribeCount == 0)
    }

    /// 2. primary 丟 .mmapUnusable → 無縫接上 secondary，消費端看到連續串流。
    @Test func mmapUnusableSwitchesSeamlessly() async {
        let primary = ScriptedTransport([.error(TransportError.mmapUnusable("全零"))])
        let secondary = ScriptedTransport([.frames([7, 8])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        let (tags, err) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [7, 8])          // 消費端只看到 secondary 的幀，沒有錯誤
        #expect(err == nil)
        #expect(secondary.subscribeCount == 1)
    }

    /// 3. 切換後不再嘗試 primary（同一 instance 內的後續掛載直接走 secondary）。
    @Test func afterFallbackPrimaryIsNeverRetried() async {
        let primary = ScriptedTransport([.error(TransportError.mmapUnusable("全零"))])
        let secondary = ScriptedTransport([.frames([1]), .frames([2])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        _ = await collect(fb.frames(width: 4, height: 4), max: 10)
        let countAfterFirst = primary.subscribeCount
        let (tags, _) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [2])
        #expect(primary.subscribeCount == countAfterFirst)   // primary 沒有被再次訂閱
        #expect(secondary.subscribeCount == 2)
    }

    /// 4. **最關鍵的一條**：.unavailable 是斷線，必須照常傳播、**不得**降級。
    /// 誤判的後果是「使用者斷線一次就永遠回不到 MMAP」——而那種 bug 不會有人回報。
    @Test func unavailableIsPropagatedNotFallenBackOn() async {
        let primary = ScriptedTransport([.framesThenError([5], TransportError.unavailable("斷線"))])
        let secondary = ScriptedTransport([.frames([9])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        let (tags, err) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [5])
        #expect(err as? TransportError == TransportError.unavailable("斷線"))
        #expect(secondary.subscribeCount == 0)               // 沒有降級
    }

    /// primary 已送出有效幀後才丟 .mmapUnusable —— 仍然降級，且已送的幀不重送。
    @Test func lateMmapUnusableStillFallsBackWithoutDuplicatingFrames() async {
        let primary = ScriptedTransport([.framesThenError([1], TransportError.mmapUnusable("轉為全零"))])
        let secondary = ScriptedTransport([.frames([2, 3])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        let (tags, err) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [1, 2, 3])
        #expect(err == nil)
    }

    /// primary 正常結束（非錯誤）→ 不降級，串流照常結束。
    @Test func primaryFinishingCleanlyDoesNotFallBack() async {
        let primary = ScriptedTransport([.frames([4])])
        let secondary = ScriptedTransport([.frames([9])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        let (tags, err) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [4])
        #expect(err == nil)
        #expect(secondary.subscribeCount == 0)
    }

    // MARK: - 補充覆蓋率：非 TransportError 的通用錯誤路徑（brief 6 條驗收測試未覆蓋到）

    /// primary 丟出非 TransportError 的一般錯誤 → 落入泛用 catch，照常傳播，不降級。
    @Test func primaryGenericErrorIsPropagated() async {
        let primary = ScriptedTransport([.error(GenericError())])
        let secondary = ScriptedTransport([.frames([9])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        let (tags, err) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [])
        #expect(err is GenericError)
        #expect(secondary.subscribeCount == 0)
    }

    /// 降級後 secondary 本身也丟錯 → 錯誤照常傳播給消費端。
    @Test func secondaryErrorAfterFallbackIsPropagated() async {
        let primary = ScriptedTransport([.error(TransportError.mmapUnusable("全零"))])
        let secondary = ScriptedTransport([.error(GenericError())])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        let (tags, err) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [])
        #expect(err is GenericError)
    }
}

/// 用來驗證「非 TransportError」錯誤路徑的一般錯誤型別。
private struct GenericError: Error, Equatable, Sendable {}
