import Foundation
import GRPC

/// `streamAudio` 的 gRPC 封裝。持有真正的 call 物件，讓 `cancelStream()` 能中斷
/// 一條「guest 靜音時會無限阻塞」的串流（proto 明載此行為）。
public final class GrpcAudioTransport: AudioTransport, @unchecked Sendable {
    private let channel: GrpcChannelBox
    // call 型別非 Sendable，用鎖保護；@unchecked Sendable 的理由與既有 GrpcChannelBox 相同。
    private let lock = NSLock()
    private var call: GRPCAsyncServerStreamingCall<
        Android_Emulation_Control_AudioFormat,
        Android_Emulation_Control_AudioPacket
    >?

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
        lock.lock(); self.call = call; lock.unlock()

        // 只捕捉 responseStream（grpc-swift 明確標 Sendable），不捕捉 call 本身，
        // 否則 Task 閉包跨隔離傳遞會觸發 strict-concurrency 資料競爭警告。
        let responses = call.responseStream
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await packet in responses {
                        if Task.isCancelled { return }
                        cont.yield(AudioChunk.fromS16LE(packet.audio))
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
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
