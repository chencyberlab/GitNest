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
        XCTAssertEqual(GitConfig.unescapeGitConfigValue("\"form\\ffeed\""), "form\u{0C}feed")
        XCTAssertEqual(GitConfig.unescapeGitConfigValue("\"\\101BC\""), "ABC")
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

    // MARK: - Alias validation

    /// An alias read from disk (a hand-edited or externally-managed gitconfig)
    /// flows into file paths (`id_<alias>`), the SSH host suffix, and
    /// `gh auth switch -u <alias>`. A malformed alias must be rejected rather
    /// than load an account whose key paths would point somewhere surprising.
    /// `Shell.run`'s argv array already prevents injection — this guards the
    /// filesystem/account-identity invariants.
    func testLoadAccountsRejectsAliasFromUrlKeyThatIsNotAValidLogin() {
        // An `insteadOf` url whose host suffix contains ".. would make
        // ~/.ssh/id_../ and github-.. resolve outside the account's namespace.
        let global = """
        [includeIf "gitdir:/tmp/github_traversal/"]
            path = /tmp/.gitconfig-traversal
        """
        let accountConfig = """
        [user]
            name = Traversal
            email = trav@example.com
        [url "git@github-..:"]
            insteadOf = https://github.com/
        """

        let accounts = GitConfig.loadAccounts(from: global) { _ in accountConfig }

        XCTAssertTrue(accounts.isEmpty, "an alias containing '..' must not be loaded")
    }

    func testLoadAccountsRejectsFolderConventionAliasThatIsNotAValidLogin() {
        // No url key: alias falls back to the folder convention. A folder named
        // "github_bad alias" (space) yields an invalid login-shaped alias.
        let global = """
        [includeIf "gitdir:/tmp/github_bad alias/"]
            path = /tmp/.gitconfig-badalias
        """
        let accountConfig = """
        [user]
            name = Bad
            email = bad@example.com
        """

        let accounts = GitConfig.loadAccounts(from: global) { _ in accountConfig }

        XCTAssertTrue(accounts.isEmpty, "an alias with a space must not be loaded")
    }

    /// A name fallback that happens to be a valid login is still accepted — only
    /// genuinely malformed aliases are rejected, so normal accounts load fine.
    func testLoadAccountsAcceptsValidAliasDerivedFromNameFallback() {
        let global = """
        [includeIf "gitdir:/tmp/Projects/"]
            path = /tmp/.gitconfig-dev
        """
        // No url key and no folder convention: alias falls back to name, which
        // is a valid login here.
        let accountConfig = """
        [user]
            name = dev
            email = dev@example.com
        """

        let accounts = GitConfig.loadAccounts(from: global) { _ in accountConfig }

        XCTAssertEqual(accounts.map(\.alias), ["dev"])
    }

    // MARK: File-read error surfacing

    func testLoadAccountsReportsUnreadableGitconfig() throws {
        // A directory exists at the path but can't be read as a file, so the load
        // must surface the fault (rather than look like a fresh, account-less setup).
        let path = NSTemporaryDirectory() + "gitnest-cfg-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }

        var errors: [String] = []
        let accounts = GitConfig.loadAccounts(gitconfigPath: path) { errors.append($0) }

        XCTAssertTrue(accounts.isEmpty)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.contains("Could not read ~/.gitconfig") == true,
                      "expected a descriptive read error, got: \(errors)")
    }

    func testLoadAccountsIsQuietWhenGitconfigAbsent() {
        // An absent file is the normal fresh-install case — return [] without noise.
        let path = NSTemporaryDirectory() + "gitnest-missing-\(UUID().uuidString)"
        var errors: [String] = []
        let accounts = GitConfig.loadAccounts(gitconfigPath: path) { errors.append($0) }

        XCTAssertTrue(accounts.isEmpty)
        XCTAssertTrue(errors.isEmpty, "an absent gitconfig must not be reported as an error")
    }

    func testLoadAccountsParsesReadableGitconfigFile() throws {
        // End-to-end through the real file-reading path: a valid global config whose
        // includeIf points at a real per-account file on disk yields one account.
        let dir = NSTemporaryDirectory() + "gitnest-cfg-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let globalPath = (dir as NSString).appendingPathComponent(".gitconfig")
        let accountPath = (dir as NSString).appendingPathComponent(".gitconfig-dev")
        try """
        [includeIf "gitdir:/tmp/github-dev/"]
            path = \(accountPath)
        """.write(toFile: globalPath, atomically: true, encoding: .utf8)
        try """
        [user]
            name = Dev
            email = dev@example.com
        [url "git@github-dev:"]
            insteadOf = https://github.com/
        """.write(toFile: accountPath, atomically: true, encoding: .utf8)

        var errors: [String] = []
        let accounts = GitConfig.loadAccounts(gitconfigPath: globalPath) { errors.append($0) }

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(accounts.map(\.alias), ["dev"])
        XCTAssertEqual(accounts.first?.email, "dev@example.com")
    }
}
