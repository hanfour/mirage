import Testing
@testable import MirageCore

/// `DisplayTransportSelector.choose(emulatorVersion:)` 是純函式（不碰 channel、不碰 gRPC、
/// 不建構任何 transport），窮舉版本字串即可完整覆蓋——不需要、也不該建 `EmulatorClient`
/// 或真 `GrpcChannelBox` 來測「該選哪一種」（Task 6 審查教訓：見 EmulatorClientReconnectTests.swift
/// 裡對應的說明與 task-6-report.md）。
@Suite struct DisplayTransportSelectorTests {
    @Test(arguments: ["37.2.1.0", "38.0.0", "40.1"])
    func versionAtOrAbove37ChoosesMmapWithRawFallback(version: String) {
        #expect(DisplayTransportSelector.choose(emulatorVersion: version) == .mmapWithRawFallback)
    }

    @Test(arguments: ["36.6.11.0", "", "abc", "unknown.1"])
    func versionBelow37OrUnparsableChoosesRawOnly(version: String) {
        #expect(DisplayTransportSelector.choose(emulatorVersion: version) == .rawOnly)
    }
}
