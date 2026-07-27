import Foundation
import Testing
@testable import MirageCore

@Suite struct MmapSupportTests {
    @Test func handlePathIsUniquePerSeq() {
        let a = MmapSupport.handlePath(tempDir: "/tmp/", pid: 42, seq: 1, width: 900, height: 2000)
        let b = MmapSupport.handlePath(tempDir: "/tmp/", pid: 42, seq: 2, width: 900, height: 2000)
        #expect(a != b)
    }

    /// 多開時不同行程不得撞路徑。
    @Test func handlePathIsUniquePerProcess() {
        let a = MmapSupport.handlePath(tempDir: "/tmp/", pid: 1, seq: 1, width: 900, height: 2000)
        let b = MmapSupport.handlePath(tempDir: "/tmp/", pid: 2, seq: 1, width: 900, height: 2000)
        #expect(a != b)
    }

    /// 路徑必須含 mirage_mmap_ 前綴——驗收線 6 靠這個前綴檢查 /tmp 殘留。
    @Test func handlePathCarriesRecognisablePrefix() {
        let p = MmapSupport.handlePath(tempDir: "/tmp/", pid: 42, seq: 1, width: 900, height: 2000)
        #expect(p.hasPrefix("/tmp/mirage_mmap_"))
        #expect(p.hasSuffix(".bin"))
    }

    @Test func tempDirWithoutTrailingSlashStillProducesValidPath() {
        let p = MmapSupport.handlePath(tempDir: "/tmp", pid: 42, seq: 1, width: 900, height: 2000)
        #expect(p.hasPrefix("/tmp/mirage_mmap_"))
        #expect(!p.contains("//"))
    }

    @Test func handleURLPrefixesFileScheme() {
        #expect(MmapSupport.handleURL(path: "/tmp/x.bin") == "file:///tmp/x.bin")
    }

    @Test func byteCountIsRGBA8888() {
        #expect(MmapSupport.byteCount(width: 900, height: 2000) == 900 * 2000 * 4)
        #expect(MmapSupport.byteCount(width: 0, height: 100) == 0)
        #expect(MmapSupport.byteCount(width: -1, height: 100) == 0)
    }

    @Test func isBlankDetectsAllZero() {
        #expect(MmapSupport.isBlank(Data(count: 1024)))
    }

    @Test func isBlankIsFalseWhenAnyByteIsNonZero() {
        var d = Data(count: 1024)
        d[1023] = 1                      // 最後一個 byte——確認掃描是完整的、不是只看開頭
        #expect(!MmapSupport.isBlank(d))
    }

    @Test func emptyDataIsBlank() {
        #expect(MmapSupport.isBlank(Data()))
    }

    @Test(arguments: ["36.6.11.0", "", "abc", "unknown.1"])
    func versionGateRejects(version: String) {
        #expect(!MmapVersionGate.allows(versionString: version))
    }

    @Test(arguments: ["37.2.1.0", "38.0.0", "40.1"])
    func versionGateAllows(version: String) {
        #expect(MmapVersionGate.allows(versionString: version))
    }
}
