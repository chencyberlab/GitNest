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

    // MARK: - Edge cases

    func testLoadAccountsStripsInlineComments() {
        let global = """
        [includeIf "gitdir:/tmp/github_carol/"] ; inline comment
            path = /tmp/.gitconfig-carol # another comment
        """
        let accountConfig = """
        [user]
            name = Carol
            email = carol@example.com
        [url "git@github-carol:"]
            insteadOf = https://github.com/
        """

        let accounts = GitConfig.loadAccounts(from: global) { path in
            path == "/tmp/.gitconfig-carol" ? accountConfig : nil
        }

        XCTAssertEqual(accounts.map(\.alias), ["carol"])
    }

    func testLoadAccountsUnquotesPathValue() {
        let global = """
        [includeIf "gitdir:/tmp/github_dave/"]
            path = "/tmp/.gitconfig-dave"
        """
        let accountConfig = """
        [user]
            name = Dave
            email = dave@example.com
        [url "git@github-dave:"]
            insteadOf = https://github.com/
        """

        let accounts = GitConfig.loadAccounts(from: global) { path in
            path == "/tmp/.gitconfig-dave" ? accountConfig : nil
        }

        XCTAssertEqual(accounts.map(\.alias), ["dave"])
    }

    func testLoadAccountsFallsBackToFolderAlias() {
        let global = """
        [includeIf "gitdir:/tmp/github_eve/"]
            path = /tmp/.gitconfig-eve
        """
        let accountConfig = """
        [user]
            name = Eve
            email = eve@example.com
        """

        let accounts = GitConfig.loadAccounts(from: global) { path in
            path == "/tmp/.gitconfig-eve" ? accountConfig : nil
        }

        XCTAssertEqual(accounts.map(\.alias), ["eve"])
        XCTAssertEqual(accounts.first?.folder, "/tmp/github_eve")
    }

    func testLoadAccountsReturnsEmptyWhenAccountFileMissing() {
        let global = """
        [includeIf "gitdir:/tmp/github_ghost/"]
            path = /tmp/missing
        """

        let accounts = GitConfig.loadAccounts(from: global) { _ in nil }

        XCTAssertTrue(accounts.isEmpty)
    }

    func testUnescapeGitConfigValueHandlesQuotedEscapes() {
        XCTAssertEqual(GitConfig.unescapeGitConfigValue("\"Alice\\\"s\""), "Alice\"s")
        XCTAssertEqual(GitConfig.unescapeGitConfigValue("\"a@b\\com\""), "a@b\\com")
        XCTAssertEqual(GitConfig.unescapeGitConfigValue("\"line1\\nline2\""), "line1\nline2")
        XCTAssertEqual(GitConfig.unescapeGitConfigValue("\"tab\\there\""), "tab\there")
        XCTAssertEqual(GitConfig.unescapeGitConfigValue("plain"), "plain")
    }

    func testLoadAccountsHandlesUnderscoreFolderConvention() {
        let global = """
        [includeIf "gitdir:/Users/dev/github_work/"]
            path = /tmp/.gitconfig-work
        """
        let accountConfig = """
        [user]
            name = Work
            email = work@example.com
        [url "git@github-work:"]
            insteadOf = https://github.com/
        """

        let accounts = GitConfig.loadAccounts(from: global) { path in
            path == "/tmp/.gitconfig-work" ? accountConfig : nil
        }

        XCTAssertEqual(accounts.map(\.alias), ["work"])
    }

    func testLoadAccountsIgnoresDuplicateAliasFromMultipleFolders() {
        let global = """
        [includeIf "gitdir:/tmp/github_alice/"]
            path = /tmp/.gitconfig-alice
        [includeIf "gitdir:/tmp/github_alice2/"]
            path = /tmp/.gitconfig-alice
        """
        let accountConfig = """
        [user]
            name = Alice
            email = alice@example.com
        [url "git@github-alice:"]
            insteadOf = https://github.com/
        """

        let accounts = GitConfig.loadAccounts(from: global) { _ in accountConfig }

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.folder, "/tmp/github_alice")
    }
}
