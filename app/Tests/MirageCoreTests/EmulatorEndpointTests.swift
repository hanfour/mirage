import Testing
@testable import MirageCore

@Suite("EmulatorEndpoint")
struct EmulatorEndpointTests {
    @Test func absentOverridesGiveTheDefaultEndpoint() {
        let e = EmulatorEndpoint.resolve(environment: [:])
        #expect(e.host == "localhost")
        #expect(e.port == 8554)
        #expect(e.overrideProblem == nil)
    }

    @Test func portOverrideIsApplied() {
        let e = EmulatorEndpoint.resolve(environment: ["MIRAGE_PORT": "8556"])
        #expect(e.host == "localhost")
        #expect(e.port == 8556)
        #expect(e.overrideProblem == nil)
    }

    @Test func hostOverrideIsApplied() {
        let e = EmulatorEndpoint.resolve(environment: ["MIRAGE_HOST": "10.0.0.7"])
        #expect(e.host == "10.0.0.7")
        #expect(e.port == 8554)
        #expect(e.overrideProblem == nil)
    }

    @Test func bothOverridesApplyTogether() {
        let e = EmulatorEndpoint.resolve(
            environment: ["MIRAGE_HOST": "10.0.0.7", "MIRAGE_PORT": "8556"])
        #expect(e.host == "10.0.0.7")
        #expect(e.port == 8556)
        #expect(e.overrideProblem == nil)
    }

    /// 打錯的 port 不能靜默退回預設——那會讓使用者連上**另一台**模擬器卻毫無訊號。
    /// 這正是 MMAP 階段學到的教訓（`RESULTS-mmap.md`：降級無訊號 = 使用者看到錯誤畫面）。
    @Test func nonNumericPortFallsBackAndSaysWhy() throws {
        let e = EmulatorEndpoint.resolve(environment: ["MIRAGE_PORT": "abc"])
        #expect(e.port == 8554)
        #expect(try #require(e.overrideProblem).contains("abc"))
    }

    @Test(arguments: ["0", "-1", "65536", "99999"])
    func outOfRangePortFallsBackAndSaysWhy(_ raw: String) throws {
        let e = EmulatorEndpoint.resolve(environment: ["MIRAGE_PORT": raw])
        #expect(e.port == 8554)
        #expect(try #require(e.overrideProblem).contains(raw))
    }

    @Test func boundaryPortsAreAccepted() {
        #expect(EmulatorEndpoint.resolve(environment: ["MIRAGE_PORT": "1"]).port == 1)
        #expect(EmulatorEndpoint.resolve(environment: ["MIRAGE_PORT": "65535"]).port == 65535)
    }

    @Test func blankHostFallsBackAndSaysWhy() {
        let e = EmulatorEndpoint.resolve(environment: ["MIRAGE_HOST": "   "])
        #expect(e.host == "localhost")
        #expect(e.overrideProblem != nil)
    }

    /// 兩個覆寫都壞掉時，兩個原因都要說——只報一個會讓使用者修完第一個又撞第二個。
    @Test func bothProblemsAreReportedTogether() throws {
        let e = EmulatorEndpoint.resolve(
            environment: ["MIRAGE_HOST": "", "MIRAGE_PORT": "abc"])
        #expect(e.host == "localhost")
        #expect(e.port == 8554)
        #expect(try #require(e.overrideProblem).contains("MIRAGE_HOST"))
        #expect(try #require(e.overrideProblem).contains("MIRAGE_PORT"))
    }
}
