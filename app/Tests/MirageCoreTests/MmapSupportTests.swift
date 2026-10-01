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

    /// 路徑必須含 mirage_mmap_ 前綴——驗收線 6 靠這個前綴檢查殘留。
    /// （本測試傳入的 tempDir 是 `/tmp`；產品實際拿的是 `NSTemporaryDirectory()`，
    /// 在 macOS 上回傳 `$TMPDIR`。`verify_mmap.sh` 因此兩個目錄都掃——它原本只掃
    /// `/tmp`，於是那條檢查恆為 PASS，2026-08-05 D39 修掉。）
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
        #expect(MmapSupport.byteCount(width: Int.max, height: Int.max) == 0)
    }

    /// emulator 可能少回一欄；共享區前段依實際寬度緊密排列，Frame 只取實際像素長度。
    @Test func frameUses859By1910PrefixFrom860By1910Buffer() throws {
        let actualByteCount = MmapSupport.byteCount(width: 859, height: 1910)
        let requestedByteCount = MmapSupport.byteCount(width: 860, height: 1910)
        var buffer = Data(repeating: 0x37, count: actualByteCount)
        buffer.append(Data(repeating: 0xE5, count: requestedByteCount - actualByteCount))

        let frame = try #require(MmapSupport.frame(width: 859, height: 1910, buffer: buffer))

        #expect(frame.width == 859)
        #expect(frame.height == 1910)
        #expect(frame.rgba.count == actualByteCount)
        #expect(frame.rgba[actualByteCount - 1] == 0x37)
        #expect(frame.isValid)
    }

    @Test func frameUses898By1995PrefixFrom898By1996Buffer() throws {
        let actualByteCount = MmapSupport.byteCount(width: 898, height: 1995)
        let requestedByteCount = MmapSupport.byteCount(width: 898, height: 1996)
        let buffer = Data(repeating: 0x5A, count: requestedByteCount)

        let frame = try #require(MmapSupport.frame(width: 898, height: 1995, buffer: buffer))

        #expect(frame.width == 898)
        #expect(frame.height == 1995)
        #expect(frame.rgba.count == actualByteCount)
        #expect(frame.isValid)
    }

    @Test func frameRejectsZeroDimensions() {
        let zeroWidth = MmapSupport.frame(width: 0, height: 1910, buffer: Data(count: 4)) == nil
        let zeroHeight = MmapSupport.frame(width: 859, height: 0, buffer: Data(count: 4)) == nil

        #expect(zeroWidth)
        #expect(zeroHeight)
    }

    @Test func frameRejectsPixelsLargerThanTheMappedBuffer() {
        let expectedByteCount = MmapSupport.byteCount(width: 4, height: 2)
        let rejected = MmapSupport.frame(
            width: 4,
            height: 2,
            buffer: Data(count: expectedByteCount - 1)
        ) == nil

        #expect(rejected)
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
