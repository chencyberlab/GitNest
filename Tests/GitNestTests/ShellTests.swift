import XCTest
@testable import GitNest

final class ShellTests: XCTestCase {
    func testRunsACommandDirectlyAndCapturesStdout() {
        let res = Shell.run(["echo", "hello world"])

        XCTAssertTrue(res.ok)
        XCTAssertEqual(res.stdout, "hello world\n")
        XCTAssertEqual(res.stderr, "")
    }

    func testArgumentsAreNotShellInterpreted() {
        // With no intermediate shell, metacharacters arrive as literal bytes.
        let tricky = "$(touch /tmp/pwned); `id` '\"; rm -rf"
        let res = Shell.run(["echo", tricky])

        XCTAssertTrue(res.ok)
        XCTAssertEqual(res.stdout, tricky + "\n")
    }

    func testNonZeroExitIsReported() {
        let res = Shell.run(["false"])

        XCTAssertFalse(res.ok)
    }

    func testMissingCommandFailsCleanly() {
        let res = Shell.run(["definitely-not-a-real-binary-gitnest"])

        XCTAssertFalse(res.ok)
        XCTAssertEqual(res.exitCode, 127)
        XCTAssertTrue(res.stderr.contains("command not found"))
    }

    func testTimeoutKillsTheProcessAndSaysSo() {
        let started = Date()
        let res = Shell.run(["sleep", "30"], timeout: 1)

        XCTAssertFalse(res.ok)
        XCTAssertTrue(res.stderr.contains("timed out"))
        // Well under the sleep duration: the process was actually terminated.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testTimeoutKillsChildHoldingOutputPipeOpen() {
        let started = Date()
        let res = Shell.run(["sh", "-c", "sleep 30 & exit 0"], timeout: 1)

        XCTAssertFalse(res.ok)
        XCTAssertTrue(res.stderr.contains("timed out"))
        // The direct shell exits immediately; this only returns quickly if the
        // background child in the same process group is also terminated.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testAbandonsReadersWhenAnEscapedChildHoldsThePipe() {
        let started = Date()
        // The forked grandchild calls setsid(), leaving the command's process
        // group entirely, while keeping the inherited stdout open — the one
        // shape the group kill cannot reach. The call must still return.
        let script = "use POSIX qw(setsid); exit 0 if fork(); setsid(); sleep 30;"
        let res = Shell.run(["perl", "-e", script], timeout: 1, killGracePeriod: 0.5)

        XCTAssertFalse(res.ok)
        XCTAssertTrue(res.stderr.contains("timed out"))
        XCTAssertTrue(res.stderr.contains("abandoned"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testTimedOutCommandStillReportsPartialOutput() {
        let res = Shell.run(["sh", "-c", "echo started; sleep 30"], timeout: 1)

        XCTAssertFalse(res.ok)
        XCTAssertEqual(res.stdout, "started\n")
        XCTAssertTrue(res.stderr.contains("timed out"))
    }

    func testStdinIsDevNullSoToolsNeverWaitForInput() {
        let started = Date()
        let res = Shell.run(["cat"], timeout: 5)

        XCTAssertTrue(res.ok)
        XCTAssertEqual(res.stdout, "")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testChildInheritsOnlyStandardDescriptors() {
        // The test runner has many fds open; CLOEXEC_DEFAULT must keep them
        // out of the child. /dev/fd shows the child shell's own table: stdio
        // plus the descriptor ls itself uses to read the /dev/fd directory.
        let res = Shell.run(["sh", "-c", "ls /dev/fd"])

        XCTAssertTrue(res.ok)
        let fds = res.stdout.split(whereSeparator: \.isNewline).compactMap { Int($0) }
        XCTAssertFalse(fds.isEmpty)
        XCTAssertTrue(fds.allSatisfy { $0 <= 4 }, "unexpected inherited fds: \(fds)")
    }

    func testResolveExecutableFindsCoreTools() {
        for tool in ["git", "ssh", "mkdir", "chmod"] {
            let path = Shell.resolveExecutable(tool)
            XCTAssertNotNil(path, "\(tool) should resolve")
            XCTAssertTrue(path?.hasPrefix("/") == true)
        }
    }

    func testResolveExecutablePassesThroughExplicitPaths() {
        XCTAssertEqual(Shell.resolveExecutable("/bin/echo"), "/bin/echo")
    }
}
