import Testing
@testable import MirageCore

@Suite("InstanceTable")
struct InstanceTableTests {
    @Test func parsesTwoEntries() throws {
        let entries = try InstanceTable.parse("""
            mirage-game:5554:8554
            mirage-poc:5556:8556
            """).get()
        #expect(entries == [
            InstanceEntry(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554),
            InstanceEntry(avdName: "mirage-poc", consolePort: 5556, grpcPort: 8556),
        ])
    }

    @Test func ignoresBlankLinesAndComments() throws {
        let entries = try InstanceTable.parse("""
            # default instance

              # an indented comment
            mirage-game:5554:8554

            """).get()
        #expect(entries == [InstanceEntry(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554)])
    }

    @Test func rejectsOddConsolePortAndReportsLine() throws {
        let error = try #require(failure("first:5554:8554\nsecond:5555:8556"))
        #expect(error.line == 2)
        #expect(error.reason.contains("5554–5682 的偶數"))
    }

    @Test func rejectsConsolePortOutsideRange() throws {
        let error = try #require(failure("game:5552:8554"))
        #expect(error.line == 1)
        #expect(error.reason.contains("5554–5682"))
    }

    @Test func rejectsGrpcPortOutsideRange() throws {
        let error = try #require(failure("game:5554:65536"))
        #expect(error.reason.contains("1–65535"))
    }

    @Test func rejectsDuplicateAvdName() throws {
        let error = try #require(failure("game:5554:8554\ngame:5556:8556"))
        #expect(error.line == 2)
        #expect(error.reason.contains("AVD 名稱 game 重複"))
    }

    @Test func rejectsDuplicateConsoleOrGrpcPort() throws {
        let consoleError = try #require(failure("one:5554:8554\ntwo:5554:8556"))
        #expect(consoleError.reason.contains("console 埠 5554 重複"))

        let grpcError = try #require(failure("one:5554:8554\ntwo:5556:8554"))
        #expect(grpcError.reason.contains("gRPC 埠 8554 重複"))
    }

    @Test func rejectsEmptyOrCommentOnlyTable() throws {
        let emptyError = try #require(failure(""))
        #expect(emptyError.reason.contains("不能是空白"))

        let commentError = try #require(failure("# no instances\n\n"))
        #expect(commentError.reason.contains("不能是空白"))
    }

    @Test func bundledTableLoads() throws {
        let entries = try InstanceTable.bundled().get()
        #expect(entries.count == 2)
    }

    private func failure(_ text: String) -> InstanceTableError? {
        guard case .failure(let error) = InstanceTable.parse(text) else { return nil }
        return error
    }
}
