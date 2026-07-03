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

    func testProvidedStdinIsPassedToChild() {
        let res = Shell.run(["cat"], stdin: Data("secret input\n".utf8))

        XCTAssertTrue(res.ok)
        XCTAssertEqual(res.stdout, "secret input\n")
    }

    func testProvidedStdinDoesNotHangWhenChildDoesNotRead() {
        let started = Date()
        let input = Data(repeating: UInt8(ascii: "x"), count: 1_000_000)
        let res = Shell.run(["true"], timeout: 5, killGracePeriod: 0.2, stdin: input)

        XCTAssertTrue(res.ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testExtraInputFDCanFeedChildHelper() {
        let script = #"IFS= read -r value < /dev/fd/3; printf '%s' "$value""#
        let res = Shell.run(["sh", "-c", script], extraInputFDs: [3: Data("pipe secret\n".utf8)])

        XCTAssertTrue(res.ok)
        XCTAssertEqual(res.stdout, "pipe secret")
    }

    func testExtraInputFDSurvivesNestedExecForAskpassHelpers() {
        let script = #"exec sh -c 'IFS= read -r value < /dev/fd/3; printf "%s" "$value"'"#
        let res = Shell.run(["sh", "-c", script], extraInputFDs: [3: Data("nested secret\n".utf8)])

        XCTAssertTrue(res.ok, res.stderr + res.stdout)
        XCTAssertEqual(res.stdout, "nested secret")
    }

    func testNeighboringExtraInputFDTargetsStayOpen() {
        let script = """
        IFS= read -r first < /dev/fd/7
        IFS= read -r second < /dev/fd/8
        printf '%s|%s' "$first" "$second"
        """
        let res = Shell.run(
            ["sh", "-c", script],
            extraInputFDs: [
                7: Data("first\n".utf8),
                8: Data("second\n".utf8),
            ]
        )

        XCTAssertTrue(res.ok, res.stderr + res.stdout)
        XCTAssertEqual(res.stdout, "first|second")
    }

    func testExtraInputFDTargetsCanOverlapRunnerPipeFDNumbers() {
        let targets = Array(3...14)
        let script = targets
            .map { #"IFS= read -r value < /dev/fd/\#($0); printf '%s\n' "$value""# }
            .joined(separator: "\n")
        let inputs = Dictionary(uniqueKeysWithValues: targets.map { fd in
            (Int32(fd), Data("fd-\(fd)\n".utf8))
        })

        let res = Shell.run(["sh", "-c", script], extraInputFDs: inputs)

        XCTAssertTrue(res.ok, res.stderr + res.stdout)
        XCTAssertEqual(res.stdout, targets.map { "fd-\($0)" }.joined(separator: "\n") + "\n")
    }

    func testTimeoutUsesDisplayArgsSoSecretsStayOutOfErrors() {
        let secret = "passphrase-should-not-be-reported"
        let res = Shell.run(
            ["sh", "-c", "sleep 30", secret],
            timeout: 1,
            displayArgs: ["sh", "-c", "sleep 30", Redaction.mask]
        )

        XCTAssertFalse(res.ok)
        XCTAssertTrue(res.stderr.contains(Redaction.mask))
        XCTAssertFalse(res.stderr.contains(secret))
    }

    func testSanitizedEnvironmentScrubsGitOverrides() {
        let env = Shell.sanitizedEnvironment(from: [
            "PATH": "/custom/bin",
            "HOME": "/Users/test",
            "GH_EDITOR": "nano",   // a benign gh pref — must be preserved
            "GIT_DIR": "/tmp/wrong.git",
            "GIT_WORK_TREE": "/tmp/wrong-worktree",
            "GIT_INDEX_FILE": "/tmp/wrong-index",
            "GIT_CONFIG_GLOBAL": "/tmp/wrong-gitconfig",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "user.name",
            "GIT_CONFIG_VALUE_0": "Wrong User",
            "GIT_SSH_COMMAND": "ssh -F /tmp/wrong-config",
            "GIT_AUTHOR_NAME": "Wrong Author",
            "GIT_AUTHOR_EMAIL": "wrong@example.com",
            "GIT_COMMITTER_NAME": "Wrong Committer",
            "GIT_COMMITTER_EMAIL": "wrong@example.com",
            "GIT_ASKPASS": "/tmp/askpass"
        ])

        XCTAssertNil(env["GIT_DIR"])
        XCTAssertNil(env["GIT_WORK_TREE"])
        XCTAssertNil(env["GIT_INDEX_FILE"])
        XCTAssertNil(env["GIT_CONFIG_GLOBAL"])
        XCTAssertNil(env["GIT_CONFIG_COUNT"])
        XCTAssertNil(env["GIT_CONFIG_KEY_0"])
        XCTAssertNil(env["GIT_CONFIG_VALUE_0"])
        XCTAssertNil(env["GIT_SSH_COMMAND"])
        XCTAssertNil(env["GIT_AUTHOR_NAME"])
        XCTAssertNil(env["GIT_AUTHOR_EMAIL"])
        XCTAssertNil(env["GIT_COMMITTER_NAME"])
        XCTAssertNil(env["GIT_COMMITTER_EMAIL"])
        XCTAssertNil(env["GIT_ASKPASS"])
        XCTAssertEqual(env["LC_ALL"], "C")
        XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(env["GH_EDITOR"], "nano")
        XCTAssertTrue(env["PATH"]?.hasSuffix(":/custom/bin") == true)
    }

    /// `gh` token/host env vars take priority over `gh auth switch`, so a stray
    /// GH_TOKEN would defeat this multi-account app's per-account verification
    /// (ensureActiveAccount, GhChain) and silently authenticate as the token's
    /// owner. They must be scrubbed so identity is controlled only by `gh auth
    /// switch`; benign gh prefs (GH_EDITOR, GH_PAGER) are preserved.
    func testSanitizedEnvironmentScrubsGhIdentityOverrides() {
        let env = Shell.sanitizedEnvironment(from: [
            "GH_TOKEN": "ghp_secret",
            "GITHUB_TOKEN": "ghp_other",
            "GH_HOST": "enterprise.example.com",
            "GH_ENTERPRISE_TOKEN": "ghp_ent",
            "GITHUB_ENTERPRISE_TOKEN": "ghp_ent2",
            "GH_CONFIG_DIR": "/tmp/other-gh-config",   // would point gh at a different account store
            "GH_EDITOR": "vim",   // benign prefs survive
            "GH_PAGER": "less"
        ])

        XCTAssertNil(env["GH_TOKEN"])
        XCTAssertNil(env["GITHUB_TOKEN"])
        XCTAssertNil(env["GH_HOST"])
        XCTAssertNil(env["GH_ENTERPRISE_TOKEN"])
        XCTAssertNil(env["GITHUB_ENTERPRISE_TOKEN"])
        XCTAssertNil(env["GH_CONFIG_DIR"])
        XCTAssertEqual(env["GH_EDITOR"], "vim")
        XCTAssertEqual(env["GH_PAGER"], "less")
    }

    func testExtraEnvironmentCannotReintroduceIdentityOverrides() {
        let script = #"printf '%s|%s|%s' "${GH_TOKEN-unset}" "${GIT_DIR-unset}" "${SAFE_VALUE-unset}""#
        let res = Shell.run(
            ["sh", "-c", script],
            extraEnv: [
                "GH_TOKEN": "ghp_secret",
                "GIT_DIR": "/tmp/wrong.git",
                "SAFE_VALUE": "ok",
            ]
        )

        XCTAssertTrue(res.ok)
        XCTAssertEqual(res.stdout, "unset|unset|ok")
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

    func testProcessHandleCancelStopsARunningCommand() {
        let handle = Shell.ProcessHandle()
        let started = Date()
        let done = expectation(description: "command returns")
        var result: ShellResult?
        DispatchQueue.global().async {
            result = Shell.run(["sleep", "30"], handle: handle)
            done.fulfill()
        }
        // Let it spawn, then kill it from another thread — like the wizard's Cancel.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { handle.cancel() }

        wait(for: [done], timeout: 10)
        XCTAssertEqual(result?.ok, false)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testProcessHandleCancelBeforeSpawnKillsImmediately() {
        let handle = Shell.ProcessHandle()
        handle.cancel()   // cancelled before the command even starts
        let started = Date()
        let res = Shell.run(["sleep", "30"], handle: handle)

        XCTAssertFalse(res.ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
