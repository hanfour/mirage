import Foundation
import GRPC

/// `streamAudio` 的 gRPC 封裝。持有真正的 call 物件，讓 `cancelStream()` 能中斷
/// 一條「guest 靜音時會無限阻塞」的串流（proto 明載此行為）。
public final class GrpcAudioTransport: AwaitableAudioTransport, @unchecked Sendable {
    private let channel: GrpcChannelBox
    // call 型別非 Sendable，用鎖保護；@unchecked Sendable 的理由與既有 GrpcChannelBox 相同。
    private let lock = NSLock()
    private var call: GRPCAsyncServerStreamingCall<
        Android_Emulation_Control_AudioFormat,
        Android_Emulation_Control_AudioPacket
    >?

    private var responseTask: Task<Void, Never>?

    private func storeResponseTask(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        responseTask = task
    }

    private func currentResponseTask() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return responseTask
    }

    public func cancelStreamAndWait() async {
        let task = currentResponseTask()
        cancelStream()
        await task?.value
    }

    public init(channel: GrpcChannelBox) { self.channel = channel }

    public func packets(format: AudioStreamFormat) -> AsyncThrowingStream<AudioChunk, Error> {
        var fmt = Android_Emulation_Control_AudioFormat()
        fmt.samplingRate = UInt64(format.samplingRate)
        fmt.channels = format.channels >= 2 ? .stereo : .mono
        fmt.format = .audFmtS16
        // modeRealTime：落後時由 emulator 覆寫佇列而非阻塞累積延遲。proto 把 mode 標為
        // [Input Only]，對 streamAudio 是否生效未經證實——不論生效與否都安全，我們自己的
        // 環形緩衝溢位丟包已經守住延遲上限。
        fmt.mode = .modeRealTime

        let call = channel.client.makeStreamAudioCall(fmt)
        // 重入保護：同一個 instance 再次呼叫 packets()（重連、喚醒、setAudioSink 二次呼叫都是
        // 常態路徑，見 Task 7）時，若不先取消舊 call 就直接覆蓋，舊 RPC 連同它的背景消費 Task
        // 會被孤兒化、cancelStream() 從此搆不到它。guest 靜音時 streamAudio 會無限阻塞，孤兒
        // call 正好卡在這個情境，且 channel 拆除時它未解決的 NIO promise 就是 P1-b
        // "leaking promise created" 致命錯誤的成因。取出舊值與存入新值都在鎖內完成，避免兩個
        // 執行緒同時呼叫 packets() 時互相覆蓋；GRPCAsyncServerStreamingCall 是 struct，取出的
        // 是值複本，鎖外對它呼叫 .cancel() 沒有 race。
        lock.lock()
        let previous = self.call
        self.call = call
        lock.unlock()
        previous?.cancel()

        // 只捕捉 responseStream（grpc-swift 明確標 Sendable），不捕捉 call 本身，
        // 否則 Task 閉包跨隔離傳遞會觸發 strict-concurrency 資料競爭警告。
        let responses = call.responseStream
        return AsyncThrowingStream { cont in
            let task = Task {
                defer { cont.finish() }
                do {
                    // **收到的格式從來沒有人檢查過。** `AudioPacket` 帶著 emulator 實際
                    // 送出的 `format`，而這裡一路假設它等於上面請求的 48000/stereo/S16——
                    // 那是「我們要求的」，不是「我們收到的」。兩者不同時，資料會被當成
                    // 48kHz 立體聲餵進環形緩衝，結果同時是變調**和**看起來像供應不足，
                    // 而供應不足正是 D44 追了很久的現象：guest 端實測以 93.6% 的即時速率
                    // 輸出音訊，Mirage 這一側只收到約 6.9%。
                    //
                    // 只在第一包與格式改變時印，避免洗版。這是診斷，不改變行為——
                    // 要不要據此重採樣是另一個決定，需要先知道實際格式是什麼。
                    var lastLoggedFormat: Android_Emulation_Control_AudioFormat?
                    for try await packet in responses {
                        if Task.isCancelled { return }
                        if packet.hasFormat, packet.format != lastLoggedFormat {
                            let f = packet.format
                            print("[audio] 收到的格式：sr=\(f.samplingRate) ch=\(f.channels) " +
                                  "fmt=\(f.format)（請求的是 sr=\(format.samplingRate) " +
                                  "ch=\(format.channels) fmt=audFmtS16）bytes=\(packet.audio.count)")
                            lastLoggedFormat = packet.format
                        }
                        cont.yield(AudioChunk.fromS16LE(packet.audio))
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            storeResponseTask(task)
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// 必須在 channel 拆除**之前**呼叫（見 EmulatorClient.dropChannel 的順序）：
    /// 先解決 in-flight promise，NIO 的 group 才不會帶著未解決的 promise 關閉而致命。
    public func cancelStream() {
        lock.lock()
        let current = call
        call = nil
        lock.unlock()
        current?.cancel()
    }
}
