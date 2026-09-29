import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct SetupLaunchOptionsTests {
    @Test func parsesSetupOverridesAndLoadsTheRequestedSpec() throws {
        let original = try SdkSpec.bundled().get()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-options-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sdk-spec.json")
        try JSONEncoder().encode(original).write(to: file)

        let options = SetupLaunchOptions.parse(environment: [
            SetupLaunchOptions.specFileKey: file.path,
            SetupLaunchOptions.autostartKey: "1",
            SetupLaunchOptions.availableBytesKey: "123456",
        ])

        #expect(options.specFile == file)
        #expect(options.autostart)
        #expect(options.fakeAvailableBytes == 123_456)
        #expect(options.warnings.isEmpty)
        #expect(try options.loadSdkSpec().get() == original)
    }

    @Test func ignoresInvalidOverridesAndReportsEachOne() {
        let options = SetupLaunchOptions.parse(environment: [
            SetupLaunchOptions.specFileKey: "",
            SetupLaunchOptions.autostartKey: "yes",
            SetupLaunchOptions.availableBytesKey: "-1",
        ])

        #expect(options.specFile == nil)
        #expect(!options.autostart)
        #expect(options.fakeAvailableBytes == nil)
        #expect(options.warnings.count == 3)
    }

    @Test func specReadFailureReturnsTheSameErrorTypeAsBundleFailure() {
        let options = SetupLaunchOptions.parse(environment: [
            SetupLaunchOptions.specFileKey: "/definitely/missing/sdk-spec.json",
        ])
        let result = options.loadSdkSpec()

        if case .failure(let error) = result {
            #expect(error.message.contains("讀取 sdk-spec.json 失敗"))
        } else {
            Issue.record("不存在的 spec 檔案不應讀取成功")
        }
    }
}
