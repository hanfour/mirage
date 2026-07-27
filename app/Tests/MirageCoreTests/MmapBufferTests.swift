import Foundation
import Testing
@testable import MirageCore

@Suite struct MmapBufferTests {
    private func tempPath(_ tag: String) -> String {
        MmapSupport.handlePath(tempDir: NSTemporaryDirectory(), pid: getpid(),
                               seq: abs(tag.hashValue % 100_000), width: 4, height: 2)
    }

    @Test func createsFileOfRequestedSize() throws {
        let path = tempPath("size")
        let buf = try #require(MmapBuffer(path: path, byteCount: 32))
        defer { buf.close() }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.size] as? Int) == 32)
    }

    @Test func snapshotStartsAllZero() throws {
        let buf = try #require(MmapBuffer(path: tempPath("zero"), byteCount: 64))
        defer { buf.close() }
        #expect(MmapSupport.isBlank(buf.snapshot()))
    }

    /// 核心行為：外部（模擬 emulator）寫入檔案後，經映射讀得到新內容。
    @Test func snapshotSeesExternalWrites() throws {
        let path = tempPath("write")
        let buf = try #require(MmapBuffer(path: path, byteCount: 8))
        defer { buf.close() }
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.write(contentsOf: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        try fh.close()
        #expect(Array(buf.snapshot()) == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    /// snapshot 必須是**複製**——回傳後即使映射區再被改寫，先前拿到的 Data 不得跟著變。
    /// 這正是「複製是正確性所必需」的形式化：Renderer 在 vsync 讀舊幀時不能被覆寫。
    @Test func snapshotIsACopyNotAView() throws {
        let path = tempPath("copy")
        let buf = try #require(MmapBuffer(path: path, byteCount: 4))
        defer { buf.close() }
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.write(contentsOf: Data([9, 9, 9, 9]))
        let first = buf.snapshot()
        try fh.seek(toOffset: 0)
        try fh.write(contentsOf: Data([1, 1, 1, 1]))
        try fh.close()
        #expect(Array(first) == [9, 9, 9, 9])       // 舊快照不受影響
        #expect(Array(buf.snapshot()) == [1, 1, 1, 1])
    }

    @Test func closeUnlinksTheFile() throws {
        let path = tempPath("unlink")
        let buf = try #require(MmapBuffer(path: path, byteCount: 16))
        #expect(FileManager.default.fileExists(atPath: path))
        buf.close()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func closeIsIdempotent() throws {
        let buf = try #require(MmapBuffer(path: tempPath("idem"), byteCount: 16))
        buf.close()
        buf.close()                                  // 不得崩潰
    }

    @Test func zeroByteCountIsRejected() {
        #expect(MmapBuffer(path: tempPath("zerolen"), byteCount: 0) == nil)
    }

    @Test func unwritablePathIsRejected() {
        #expect(MmapBuffer(path: "/this/does/not/exist/x.bin", byteCount: 16) == nil)
    }
}
