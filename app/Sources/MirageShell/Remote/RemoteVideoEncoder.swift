import CoreMedia
import CoreVideo
import Foundation
import MirageCore
import VideoToolbox

/// 編碼器抽象：`RemoteMirrorController` 只透過它餵幀、要求 keyframe、收掉 session，
/// 測試用假件取代真的 VideoToolbox（硬體編碼器在沙箱裡不一定有）。
protocol RemoteFrameEncoding: AnyObject, Sendable {
    func encode(_ frame: Frame) throws
    func requestKeyframe()
    func invalidate()
}

struct RemoteVideoEncoderSettings: Sendable, Equatable {
    var expectedFrameRate = 30
    var averageBitRate = 12_000_000
    var maxKeyFrameInterval = 120

    init() {}
}

enum RemoteVideoEncoderError: Error, Equatable {
    case sessionCreation(OSStatus)
    case property(String, OSStatus)
    case prepare(OSStatus)
    case encode(OSStatus)
    case pixelBuffer(RGBAPixelBufferError)
}

struct RemoteVideoEncoderStats: Sendable, Equatable {
    let framesSubmitted: Int
    let accessUnitsEmitted: Int
    let sessionsCreated: Int
    let framesDroppedByEncoder: Int
    let spsRewriteFailures: Int
}

/// `VTCompressionSession` 封裝（spec 第 3 節）：`Frame`（RGBA）→ BGRA `CVPixelBuffer` → AVCC →
/// NAL 清單 → `H264AccessUnitPacker`（改寫 SPS、keyframe 前置 SPS/PPS）→ `onAccessUnit`。
/// 尺寸變更時銷毀重建，新 session 的第一幀自然是 IDR、帶新的參數集。
///
/// 只用硬體編碼器：主機 CPU 是這台機器的瓶頸（`app/RESULTS-multi-instance.md`），
/// 建立失敗直接拋錯讓上層關閉功能，不退回軟體編碼（spec 第 7 節）。
final class RemoteVideoEncoder: RemoteFrameEncoding, @unchecked Sendable {
    private let settings: RemoteVideoEncoderSettings
    private let onAccessUnit: @Sendable (H264AccessUnit) -> Void
    // VT 操作串列化；回呼只拿 state lock，invalidate 等待回呼時不會互鎖。
    private let operationLock = NSLock()
    private let lock = NSLock()
    // 回呼不可同步重入 encode/invalidate；AppModel 透過 MainActor Task 處理錯誤。
    private let onError: @Sendable (String) -> Void
    private var generation: UInt64 = 0
    private var session: VTCompressionSession?
    private var sessionSize = (0, 0)   // 不加標籤：要與 `(frame.width, frame.height)` 直接比較
    private var epoch = ContinuousClock.now
    private var packer = H264AccessUnitPacker()
    private var keyframeRequested = false
    private var framesSubmitted = 0
    private var accessUnitsEmitted = 0
    private var sessionsCreated = 0
    private var framesDroppedByEncoder = 0
    private var spsRewriteFailures = 0
    private var skippedPropertyStorage: [(String, OSStatus)] = []

    init(settings: RemoteVideoEncoderSettings = .init(),
         onError: @escaping @Sendable (String) -> Void = { _ in },
         onAccessUnit: @escaping @Sendable (H264AccessUnit) -> Void)
    {
        self.onError = onError
        self.settings = settings
        self.onAccessUnit = onAccessUnit
    }

    func stats() -> RemoteVideoEncoderStats {
        lock.lock(); defer { lock.unlock() }
        return RemoteVideoEncoderStats(framesSubmitted: framesSubmitted, accessUnitsEmitted: accessUnitsEmitted,
                                       sessionsCreated: sessionsCreated, framesDroppedByEncoder: framesDroppedByEncoder,
                                       spsRewriteFailures: spsRewriteFailures)
    }

    /// 累計每次 session 建立時被硬體拒絕的可選設定（含尺寸重建）。
    var skippedProperties: [(String, OSStatus)] {
        lock.lock(); defer { lock.unlock() }
        return skippedPropertyStorage
    }

    func requestKeyframe() {
        lock.lock(); keyframeRequested = true; lock.unlock()
    }

    func invalidate() {
        operationLock.lock(); defer { operationLock.unlock() }
        lock.lock()
        generation &+= 1
        let old = session
        session = nil
        sessionSize = (0, 0)
        lock.unlock()
        if let old { VTCompressionSessionInvalidate(old) }
    }

    func encode(_ frame: Frame) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        let pixelBuffer: CVPixelBuffer
        do {
            pixelBuffer = try RGBAPixelBuffer.makeBGRA(from: frame)
        } catch let error as RGBAPixelBufferError {
            throw RemoteVideoEncoderError.pixelBuffer(error)
        }
        let current: VTCompressionSession
        if let existing = session, sessionSize == (frame.width, frame.height) {
            current = existing
        } else {
            current = try replaceSession(width: frame.width, height: frame.height, epoch: frame.receivedAt)
        }
        lock.lock()
        let outputGeneration = generation
        let pts = RemoteEncoderClock.presentationTime(of: frame.receivedAt, since: epoch)
        let force = keyframeRequested
        keyframeRequested = false
        framesSubmitted += 1
        lock.unlock()

        let properties: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            current, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil) { [self] status, flags, sample in
                handleOutput(status: status, flags: flags, sample: sample, generation: outputGeneration)
            }
        guard status == noErr else { throw RemoteVideoEncoderError.encode(status) }
    }

    // MARK: - Session

    /// operationLock 內呼叫，invalidate 不持有回呼使用的 state lock；packer 重置讓新 session 的
    /// SPS/PPS 從第一個 keyframe 重新快取，不會把舊尺寸的參數集送給手機。
    private func replaceSession(width: Int, height: Int, epoch: ContinuousClock.Instant) throws
        -> VTCompressionSession
    {
        lock.lock(); generation &+= 1; lock.unlock()
        if let old = session { VTCompressionSessionInvalidate(old) }
        session = nil
        var created: VTCompressionSession?
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any,
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let new = created else { throw RemoteVideoEncoderError.sessionCreation(status) }
        do {
            // 硬體、即時、不重排及 baseline 是必要條件；其餘屬性依硬體支援盡力設定。
            try setRequired(new, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            try setRequired(new, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            try setRequired(new, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        } catch {
            VTCompressionSessionInvalidate(new)
            throw error
        }
        setOptional(new, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        setOptional(new, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        setOptional(new, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: settings.maxKeyFrameInterval as CFNumber)
        setOptional(new, key: kVTCompressionPropertyKey_AverageBitRate, value: settings.averageBitRate as CFNumber)
        setOptional(new, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: settings.expectedFrameRate as CFNumber)
        let prepared = VTCompressionSessionPrepareToEncodeFrames(new)
        guard prepared == noErr else {
            VTCompressionSessionInvalidate(new)
            throw RemoteVideoEncoderError.prepare(prepared)
        }
        lock.lock(); defer { lock.unlock() }
        session = new
        sessionSize = (width, height)
        self.epoch = epoch
        packer = H264AccessUnitPacker()
        keyframeRequested = false
        sessionsCreated += 1
        return new
    }

    private func setRequired(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw RemoteVideoEncoderError.property(key as String, status) }
    }

    private func setOptional(_ session: VTCompressionSession, key: CFString, value: CFTypeRef) {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status != noErr else { return }
        lock.lock()
        skippedPropertyStorage.append((key as String, status))
        lock.unlock()
    }

    // MARK: - 輸出

    /// VT 的執行緒上跑。`CMSampleBuffer` 不跨執行緒：在這裡就轉成 `[Data]`。
    private func handleOutput(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?,
                              generation outputGeneration: UInt64) {
        lock.lock()
        guard generation == outputGeneration else { lock.unlock(); return }
        lock.unlock()
        guard status == noErr, let sample, !flags.contains(.frameDropped) else {
            lock.lock(); framesDroppedByEncoder += 1; lock.unlock()
            if status != noErr { onError("編碼回呼失敗：\(RemoteVideoEncoderError.encode(status))") }
            return
        }
        let nals = Self.nalUnits(of: sample)
        lock.lock()
        guard generation == outputGeneration else { lock.unlock(); return }
        var failures = 0
        let (next, unit) = packer.pack(nals) { sps in
            let rewritten = H264SpsRewriter.rewriteOrNil(sps)
            if rewritten == nil { failures += 1 }
            return rewritten
        }
        packer = next
        spsRewriteFailures += failures
        if unit != nil { accessUnitsEmitted += 1 }
        lock.unlock()
        if let unit { onAccessUnit(unit) }
    }

    /// keyframe 時先放 format description 裡的參數集（SPS、PPS，已含 emulation prevention），
    /// 再放 AVCC 切出來的 slice。長度前綴寬度由 format description 告知。
    static func nalUnits(of sample: CMSampleBuffer) -> [Data] {
        var nals: [Data] = []
        var headerLength: Int32 = 4
        if let description = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            if isKeyframe(sample) {
                for index in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    if status == noErr, let pointer { nals.append(Data(bytes: pointer, count: size)) }
                }
            }
        }
        if let block = CMSampleBufferGetDataBuffer(sample), let avcc = copyBytes(of: block) {
            if (1...4).contains(headerLength) {
                nals += H264AvccSplitter.split(avcc, headerLength: Int(headerLength))
            }
        }
        return nals
    }

    /// 沒有附件＝sync sample（CoreMedia 慣例）；有附件看 `NotSync`。
    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first,
              let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool
        else { return true }
        return !notSync
    }

    /// `CMBlockBuffer` 不保證連續，用 copy 而不是 `GetDataPointer`。
    private static func copyBytes(of block: CMBlockBuffer) -> Data? {
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }
}
