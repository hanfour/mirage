import Darwin
import Foundation
import Testing
@testable import MirageShell

/// fd 是全行程資源，這組案例彼此串行；外部驗證請另外單獨跑此 suite。
@Suite(.serialized)
struct AdbProcessLifecycleTests {
    enum BadBehavior: String, CaseIterable, Sendable {
        case ignoresTermination
        case inheritedWriter

        var script: String {
            switch self {
            case .ignoresTermination:
                // 與 trap '' TERM; sleep 60 相同，但保留 sleep PID 供 teardown 清理。
                return "trap '' TERM\n/bin/sleep 60 &\necho \"$$ $!\" >> \"$1\"\nwait\n"
            case .inheritedWriter:
                return "/bin/sleep 60 &\necho \"$$ $!\" >> \"$1\"\nexit 0\n"
            }
        }
    }

    @Test(arguments: BadBehavior.allCases)
    func timeoutReleasesPipesAndDrains(behavior: BadBehavior) async throws {
        let fixture = try ShellFixture(body: behavior.script)
        defer { fixture.cleanUp() }
        let drains = DrainCount()
        // 暖機 Foundation.Process 的共用基礎設施，避免一次性 fd 影響差值。
        let warmup = await AdbClient.runProcess(
            URL(fileURLWithPath: "/bin/echo"), ["warmup"], .seconds(2), false
        )
        #expect(warmup?.exit == 0)
        let before = try openFDCount()
        let timeout: Duration = .milliseconds(200)
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let result = await AdbClient.runProcess(
                fixture.executable, [fixture.pids.path], timeout, true,
                drainFinished: { drains.increment() }
            )
            let elapsed = start.duration(to: .now)
            #expect(result == nil)
            #expect(elapsed >= timeout)
            #expect(elapsed < timeout + .seconds(1))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while drains.value < 20 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(drains.value == 20)
        let pairs = try fixture.processPairs()
        #expect(pairs.count == 20) // 防止 fixture 根本沒啟動也被當成逾時通過。
        // writer 仍存活時就量 fd，不能先清理 fixture 讓 EOF 幫忙收尾。
        for pair in pairs { #expect(Darwin.kill(pair.child, 0) == 0) }
        let after = try openFDCount()
        #expect(after - before < 10)
        // SIGKILL 後 reap 可能晚一個排程週期；有界等待後確認直屬 shell 已退出。
        let exitDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while pairs.contains(where: { Darwin.kill($0.parent, 0) == 0 }) && ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        for pair in pairs { #expect(Darwin.kill(pair.parent, 0) == -1) }
    }

    @Test func drainsLargeMergedOutputWithoutDeadlock() async throws {
        let fixture = try ShellFixture(body: """
        /bin/dd if=/dev/zero bs=65536 count=8 2>/dev/null
        echo stderr-marker >&2
        exit 7
        """)
        defer { fixture.cleanUp() }
        let result = await AdbClient.runProcess(fixture.executable, [], .seconds(5), true)
        let output = try #require(result)
        #expect(output.exit == 7)
        #expect(output.stdout.utf8.count == 524288 + "stderr-marker\n".utf8.count)
        #expect(output.stdout.hasSuffix("stderr-marker\n"))
    }

    @Test func discardedStderrIsNotCaptured() async throws {
        let fixture = try ShellFixture(body: "echo stdout; echo stderr >&2")
        defer { fixture.cleanUp() }
        let result = await AdbClient.runProcess(fixture.executable, [], .seconds(2), false)
        #expect(result?.stdout == "stdout\n")
        #expect(result?.exit == 0)
    }

    @Test func eofDoesNotWaitForeverForProcessExit() async throws {
        let fixture = try ShellFixture(body: """
        exec 1>/dev/null 2>/dev/null
        trap '' TERM
        /bin/sleep 60 &
        echo "$$ $!" >> "$1"
        wait
        """)
        defer { fixture.cleanUp() }
        let drains = DrainCount()
        let invocation = Task {
            await AdbClient.runProcess(
                fixture.executable, [fixture.pids.path], .seconds(2), true,
                drainFinished: { drains.increment() }
            )
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1700))
        while drains.value == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(drains.value == 1) // EOF 後至多等一秒，不必等兩秒 watchdog。
        let result = await invocation.value
        #expect(result == nil)
    }

    @Test func launchFailureDoesNotLeakPipes() async throws {
        let fixture = try ShellFixture(body: "exit 0")
        defer { fixture.cleanUp() }
        let missing = fixture.directory.appendingPathComponent("missing")
        let before = try openFDCount()
        for _ in 0..<20 {
            let result = await AdbClient.runProcess(missing, [], .seconds(1), true)
            #expect(result == nil)
        }
        let after = try openFDCount()
        #expect(after - before < 10)
    }

    @Test func concurrentStartupRunsOnceWithNullOutput() async throws {
        let fixture = try ShellFixture(body: """
        echo "$1" >> "$(dirname "$0")/calls"
        if [ -c /dev/fd/1 ] && [ -c /dev/fd/2 ]; then
            echo null-outputs >> "$(dirname "$0")/outputs"
        fi
        /bin/sleep 60 &
        echo "$$ $!" >> "$(dirname "$0")/pids"
        exit 0
        """)
        defer { fixture.cleanUp() }
        let startup = AdbServerStartup()
        let start = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { await startup.prepare(fixture.executable) } }
        }
        await startup.prepare(fixture.executable)
        #expect(start.duration(to: .now) < .seconds(1))
        let calls = try String(contentsOf: fixture.directory.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls == "start-server\n")
        let outputs = try String(contentsOf: fixture.directory.appendingPathComponent("outputs"), encoding: .utf8)
        #expect(outputs == "null-outputs\n")
    }

    @Test func failedStartupDoesNotPreventClientCall() async throws {
        let fixture = try ShellFixture(body: """
        echo "$1" >> "$(dirname "$0")/calls"
        if [ "$1" = start-server ]; then exit 1; fi
        echo Success
        """)
        defer { fixture.cleanUp() }
        let client = AdbClient(adbPath: fixture.executable, serial: "test")
        let first = await client.install(apkURL: fixture.directory.appendingPathComponent("test.apk"))
        let second = await client.install(apkURL: fixture.directory.appendingPathComponent("test.apk"))
        #expect(first == .success)
        #expect(second == .success)
        let calls = try String(contentsOf: fixture.directory.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls == "start-server\n-s\n-s\n")
    }

    @Test func completionRacingTimeoutResumesOnceAndReleasesDrains() async throws {
        let fixture = try ShellFixture(body: "/bin/sleep 0.01; echo finished")
        defer { fixture.cleanUp() }
        let drains = DrainCount()
        for _ in 0..<30 {
            let result = await AdbClient.runProcess(
                fixture.executable, [], .milliseconds(15), true,
                drainFinished: { drains.increment() }
            )
            if let result {
                #expect(result.exit == 0)
                #expect(result.stdout == "finished\n")
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while drains.value < 30 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(drains.value == 30)
    }

    private func openFDCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }
}

private final class DrainCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}

private struct ShellFixture: Sendable {
    let directory: URL
    var executable: URL { directory.appendingPathComponent("fake-adb") }
    var pids: URL { directory.appendingPathComponent("pids") }

    init(body: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func processPairs() throws -> [(parent: pid_t, child: pid_t)] {
        let contents = try String(contentsOf: pids, encoding: .utf8)
        return try contents.split(separator: "\n").map { line in
            let fields = line.split(separator: " ")
            try #require(fields.count == 2)
            let parent = try #require(Int32(fields[0]))
            let child = try #require(Int32(fields[1]))
            return (parent, child)
        }
    }

    func cleanUp() {
        // 測試自己的背景 sleep，不殺 adb server 或其他外部行程。
        if let pairs = try? processPairs() {
            for pair in pairs { Darwin.kill(pair.child, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
