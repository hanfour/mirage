import Testing
@testable import MirageCore

/// `DisplayTransportSelector.choose(emulatorVersion:mmapOptIn:)` 是純函式（不碰 channel、
/// 不碰 gRPC、不建構任何 transport），窮舉版本字串 × opt-in 兩個維度即可完整覆蓋——不需要、
/// 也不該建 `EmulatorClient` 或真 `GrpcChannelBox` 來測「該選哪一種」（Task 6 審查教訓：見
/// EmulatorClientReconnectTests.swift 裡對應的說明與 task-6-report.md）。
///
/// MMAP 需要**兩個條件同時成立**才會被選中：`mmapOptIn == true` 且版本 ≥37。少了任何一個
/// 都落回 `.rawOnly`——尤其是 `mmapOptIn == false` 但版本 ≥37 那一格，是本次「預設改回
/// raw、MMAP 需環境變數選擇加入」變更的核心行為，務必涵蓋（見 MmapSupport.swift 內
/// DisplayTransportSelector 上的裁決說明）。
@Suite struct DisplayTransportSelectorTests {
    @Test(arguments: ["37.2.1.0", "38.0.0", "40.1"])
    func optInWithVersionAtOrAbove37ChoosesMmapWithRawFallback(version: String) {
        #expect(DisplayTransportSelector.choose(emulatorVersion: version, mmapOptIn: true) == .mmapWithRawFallback)
    }

    @Test(arguments: ["36.6.11.0", "", "abc", "unknown.1"])
    func optInWithVersionBelow37OrUnparsableChoosesRawOnly(version: String) {
        #expect(DisplayTransportSelector.choose(emulatorVersion: version, mmapOptIn: true) == .rawOnly)
    }

    @Test(arguments: ["37.2.1.0", "38.0.0", "40.1"])
    func noOptInWithVersionAtOrAbove37ChoosesRawOnly(version: String) {
        #expect(DisplayTransportSelector.choose(emulatorVersion: version, mmapOptIn: false) == .rawOnly)
    }

    @Test(arguments: ["36.6.11.0", "", "abc", "unknown.1"])
    func noOptInWithVersionBelow37OrUnparsableChoosesRawOnly(version: String) {
        #expect(DisplayTransportSelector.choose(emulatorVersion: version, mmapOptIn: false) == .rawOnly)
    }
}
