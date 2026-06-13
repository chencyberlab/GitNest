import XCTest
@testable import GitNest

final class AccountSetupTests: XCTestCase {
    func testContainsHostEntryMatchesRealHostLinesOnly() {
        let config = """
        # Host github-alice
        Host github-alice-old
            HostName github.com

        Host github-bob github-alice
            HostName github.com
        """

        XCTAssertTrue(AccountSetup.containsHostEntry(host: "github-alice", in: config))
        XCTAssertFalse(AccountSetup.containsHostEntry(host: "github-charlie", in: config))
    }

    func testContainsHostEntryIsCaseInsensitiveAndExact() {
        let config = """
        Host GitHub-Alice
        Host github-alice-extra
        """

        XCTAssertTrue(AccountSetup.containsHostEntry(host: "github-alice", in: config))
        XCTAssertFalse(AccountSetup.containsHostEntry(host: "github-ali", in: config))
    }

    func testSSHLoginParsesGitHubGreeting() {
        let greeting = "Hi Octo-Cat! You've successfully authenticated, but GitHub does not provide shell access."

        XCTAssertEqual(AccountSetup.sshLogin(from: greeting), "Octo-Cat")
        XCTAssertNil(AccountSetup.sshLogin(from: "git@github.com: Permission denied (publickey)."))
    }

    func testVerificationRequiresExpectedSSHAndGhLogin() {
        let wrongSSH = AccountSetup.verification(
            expectedAlias: "alice",
            sshText: "Hi bob! You've successfully authenticated.",
            ghLogin: "alice"
        )
        XCTAssertFalse(wrongSSH.sshOK)
        XCTAssertTrue(wrongSSH.ghOK)
        XCTAssertFalse(wrongSSH.ok)

        let wrongGh = AccountSetup.verification(
            expectedAlias: "alice",
            sshText: "Hi Alice! You've successfully authenticated.",
            ghLogin: "bob"
        )
        XCTAssertTrue(wrongGh.sshOK)
        XCTAssertFalse(wrongGh.ghOK)
        XCTAssertFalse(wrongGh.ok)
    }

    func testBackupDestinationIncludesTimestampAndNonce() {
        let path = "/Users/example/.gitconfig"
        let backup = AccountSetup.backupDestination(for: path,
                                                    timestamp: "20260603-101112",
                                                    nonce: "abcdef12-3456")

        XCTAssertEqual(backup, "/Users/example/.gitconfig.backup-20260603-101112-abcdef12")
    }

    func testIncludeKeysPointingMatchesEveryRuleForTheSameAccountAcrossFolders() {
        // Two folders point at the same per-account config — the stale-rule cleanup
        // must catch both so re-running the wizard can't leave an orphan behind.
        let home = NSHomeDirectory()
        let output = [
            "includeIf.gitdir:~/Developer/github-work/.path\n~/.gitconfig-work",
            "includeIf.gitdir:~/Old/github-work/.path\n\(home)/.gitconfig-work",
            "includeIf.gitdir:~/Developer/github-home/.path\n~/.gitconfig-home",
        ].joined(separator: "\0") + "\0"

        let keys = AccountSetup.includeKeysPointing(to: "~/.gitconfig-work", inNullDelimited: output)

        XCTAssertEqual(keys, [
            "includeIf.gitdir:~/Developer/github-work/.path",   // portable value
            "includeIf.gitdir:~/Old/github-work/.path",         // expanded value, same file
        ])
    }

    func testIncludeKeysPointingIgnoresUnrelatedKeys() {
        let output = [
            "user.name\nWork User",                                  // not an includeIf rule
            "includeIf.gitdir:~/Developer/github-home/.path\n~/.gitconfig-home",   // different account
            "includeIf.gitdir:~/Developer/github-work/.path\n~/.gitconfig-work",
        ].joined(separator: "\0") + "\0"

        let keys = AccountSetup.includeKeysPointing(to: "~/.gitconfig-work", inNullDelimited: output)

        XCTAssertEqual(keys, ["includeIf.gitdir:~/Developer/github-work/.path"])
    }
}
