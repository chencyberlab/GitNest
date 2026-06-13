import XCTest
@testable import GitNest

final class GitConfigTests: XCTestCase {
    func testLoadAccountsParsesIncludeIfAndAccountConfigCaseInsensitively() {
        let global = """
        [includeif "gitdir/i:/tmp/github_Alice/"]
            path = "/tmp/.gitconfig-alice"
        """
        let accountConfig = """
        [USER]
            name = Alice
            email = alice@example.com
        [URL "git@github-Alice:"]
            insteadOf = https://github.com/
        """

        let accounts = GitConfig.loadAccounts(from: global) { path in
            path == "/tmp/.gitconfig-alice" ? accountConfig : nil
        }

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.alias, "Alice")
        XCTAssertEqual(accounts.first?.name, "Alice")
        XCTAssertEqual(accounts.first?.email, "alice@example.com")
        XCTAssertEqual(accounts.first?.folder, "/tmp/github_Alice")
    }

    func testLoadAccountsIgnoresStaleIncludeIfAndPrefixLookalikeKeys() {
        let global = """
        [includeIf "gitdir:/tmp/github_wrong/"]
        [user]
            path = /tmp/should-not-load

        [includeIf "gitdir:/tmp/github_bob/"]
            pathname = /tmp/should-not-load
            path = /tmp/.gitconfig-bob
        """
        let accountConfig = """
        [user]
            name = Bob
            email = bob@example.com
        [url "git@github-bob:"]
            insteadOf = https://github.com/
        """
        var requestedPaths: [String] = []

        let accounts = GitConfig.loadAccounts(from: global) { path in
            requestedPaths.append(path)
            return path == "/tmp/.gitconfig-bob" ? accountConfig : nil
        }

        XCTAssertEqual(requestedPaths, ["/tmp/.gitconfig-bob"])
        XCTAssertEqual(accounts.map(\.alias), ["bob"])
    }
}
