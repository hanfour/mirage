import Foundation
import Testing
@testable import MirageCore

@Suite("SdkSpec")
struct SdkSpecTests {
    @Test func bundledSpecContainsAllPinnedPackageFields() throws {
        let spec = try SdkSpec.bundled().get()
        #expect(spec.androidTarget == "android-35")
        #expect(spec.packages.count == 4)
        #expect(spec.packages.map(\.revision) == ["37.1.11", "37.0.1", "2", "9"])
        #expect(spec.packages.map(\.sha1) == [
            "f22f44948a2b7f0a0103645b9a639290eef92426",
            "6ae73f4de6452dc57e62ec02b68eed92a4c21661",
            "2026a06409db630b56711afdbffb457c1dbaed49",
            "b01416bc0bca12a85295dad179f9b8a1cae3d1e6",
        ])
        #expect(spec.packages.allSatisfy { !$0.url.absoluteString.isEmpty && $0.size > 0 })
        #expect(spec.avds.map(\.name) == ["mirage-poc", "mirage-game"])
        #expect(spec.configBase["target"] == spec.androidTarget)
    }

    @Test func missingRequiredFieldFailsToDecode() {
        let result = SdkSpec.decode(Data(#"{"androidTarget":"android-35"}"#.utf8))
        switch result {
        case .success:
            Issue.record("不完整的 spec 不應解碼成功")
        case .failure(let error):
            #expect(error.message.contains("格式錯誤"))
        }
    }
}
