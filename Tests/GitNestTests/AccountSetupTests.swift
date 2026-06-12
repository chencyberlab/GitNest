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
}
