import XCTest
@testable import GitNest

final class InitProjectTests: XCTestCase {
    func testRemoteLooksLikeMatchesCommonURLForms() {
        XCTAssertTrue(GitHub.remoteLooksLike("https://github.com/owner/repo.git", owner: "owner", repoName: "repo"))
        XCTAssertTrue(GitHub.remoteLooksLike("https://github.com/owner/repo", owner: "owner", repoName: "repo"))
        XCTAssertTrue(GitHub.remoteLooksLike("git@github.com:owner/repo.git", owner: "owner", repoName: "repo"))
        XCTAssertTrue(GitHub.remoteLooksLike("git@github-work:owner/repo.git", owner: "owner", repoName: "repo"))
    }

    func testRemoteLooksLikeIsCaseInsensitive() {
        XCTAssertTrue(GitHub.remoteLooksLike("git@GitHub.com:Owner/Repo.git", owner: "owner", repoName: "repo"))
    }

    func testRemoteLooksLikeRejectsOtherOwnersAndRepos() {
        XCTAssertFalse(GitHub.remoteLooksLike("git@github.com:other/repo.git", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("git@github.com:owner/other.git", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("git@gitlab.com:owner/repo.git", owner: "owner", repoName: "repo"))
    }

    func testRemoteLooksLikeRejectsGithubLookalikeHosts() {
        XCTAssertFalse(GitHub.remoteLooksLike("https://notgithub.com/owner/repo.git", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("https://github.example.com/owner/repo.git", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("git@github.example.com:owner/repo.git", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("git@github-evil.com:owner/repo.git", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("git@github-wørk:owner/repo.git", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("ssh://git@github-evil.com/owner/repo.git", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("git@github-:owner/repo.git", owner: "owner", repoName: "repo"))
    }

    func testRemoteLooksLikeRequiresExactOwnerRepoPath() {
        XCTAssertFalse(GitHub.remoteLooksLike("git@github.com:owner/repo-old.git", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("https://github.com/owner/repo-extra", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("https://github.com/owner/repo/tree/main", owner: "owner", repoName: "repo"))
    }

    func testRemoteLooksLikeKeepsDotGitInsideRepoNames() {
        // ".git" must only be stripped from the end — a Pages repo contains it
        // in the middle of its name and used to be mangled into "ownerhub.io".
        XCTAssertTrue(GitHub.remoteLooksLike(
            "git@github-me:owner/owner.github.io.git",
            owner: "owner", repoName: "owner.github.io"
        ))
        XCTAssertTrue(GitHub.remoteLooksLike(
            "https://github.com/owner/my.gitops.git",
            owner: "owner", repoName: "my.gitops"
        ))
    }

    func testRemoteLooksLikeCanRequireTheExpectedSSHHostAlias() {
        XCTAssertTrue(GitHub.remoteLooksLike(
            "git@github-work:owner/repo.git",
            owner: "owner",
            repoName: "repo",
            expectedSSHHost: "github-work"
        ))
        XCTAssertFalse(GitHub.remoteLooksLike(
            "git@github-work:owner/repo.git",
            owner: "owner",
            repoName: "repo",
            expectedSSHHost: "github-personal"
        ))
        XCTAssertTrue(GitHub.remoteLooksLike(
            "git@github.com:owner/repo.git",
            owner: "owner",
            repoName: "repo",
            expectedSSHHost: "github-personal"
        ))
    }

    @MainActor
    func testMakeInitPlanCapsLongSanitizedRepoName() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folderName = String(repeating: "a", count: 120)
        let source = root.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: root.path)

        let plan = await AppModel().projectWorkflow.makeInitPlan(sourceURL: source, account: account)

        XCTAssertEqual(plan.repoName, String(repeating: "a", count: 100))
        XCTAssertFalse(plan.willCopy)
    }

    @MainActor
    func testMakeInitPlanBlocksAccountRootFolder() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: root.path)

        let plan = await AppModel().projectWorkflow.makeInitPlan(sourceURL: root, account: account)

        XCTAssertEqual(plan.sourcePath, root.standardizedFileURL.path)
        XCTAssertEqual(plan.workingPath, root.standardizedFileURL.path)
        XCTAssertNotNil(plan.blockingReason)
    }

    @MainActor
    func testMakeInitPlanBlocksParentOfAccountRootFolder() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let accountFolder = root.appendingPathComponent("github-me")
        let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: accountFolder.path)

        let plan = await AppModel().projectWorkflow.makeInitPlan(sourceURL: root, account: account)

        XCTAssertEqual(plan.sourcePath, root.standardizedFileURL.path)
        XCTAssertNotNil(plan.blockingReason)
        XCTAssertTrue(plan.blockingReason?.contains("parent folder") == true)
    }

    func testInitAndPushProjectRefusesBlockedPlanBeforeShellingOut() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: root.path)
        let plan = ProjectInitPlan(
            account: account,
            sourcePath: root.path,
            workingPath: root.path,
            repoName: "blocked",
            willCopy: false,
            blockingReason: "blocked for test"
        )

        let result = GitHub.initAndPushProject(plan, visibility: .private)

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.stderr.contains("blocked for test"))
    }

    func testInitAndPushProjectRefusesSourceContainingAccountRootBeforeCopying() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let accountFolder = root.appendingPathComponent("github-me")
        let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: accountFolder.path)
        let plan = ProjectInitPlan(
            account: account,
            sourcePath: root.path,
            workingPath: accountFolder.appendingPathComponent(root.lastPathComponent).path,
            repoName: "unsafe-parent",
            willCopy: true
        )

        let result = GitHub.initAndPushProject(plan, visibility: .private)

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.stderr.contains("parent folder"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountFolder.path))
    }

    @MainActor
    func testInitProjectRefreshesRepoListAfterSuccessfulPush() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: root.path)
        let plan = ProjectInitPlan(
            account: account,
            sourcePath: root.path,
            workingPath: root.path,
            repoName: "new-project",
            willCopy: false
        )
        var refreshedAliases: [String] = []
        let ghChain = GhChain()
        let logStore = LogStore()
        let auth = AuthProcessController()
        let accountManager = AccountManager(ghChain: ghChain, logStore: logStore, authProcessController: auth)
        let repoManager = RepoManager(ghChain: ghChain, logStore: logStore, accountManager: accountManager)
        let workflow = ProjectWorkflow(
            ghChain: ghChain,
            logStore: logStore,
            repoManager: repoManager,
            initAndPushProject: { _, _ in
                ShellResult(exitCode: 0, stdout: "pushed", stderr: "")
            },
            refreshReposAfterInit: { account in
                refreshedAliases.append(account.alias)
            }
        )

        let ok = await workflow.initProject(plan, visibility: .private)

        XCTAssertTrue(ok)
        XCTAssertEqual(refreshedAliases, ["me"])
    }

    @MainActor
    func testInitProjectDoesNotTrashOriginalWhenSourceChangesDuringPush() async throws {        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "original\n".write(to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let accountFolder = root.appendingPathComponent("account")
        let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: accountFolder.path)
        let plan = ProjectInitPlan(
            account: account,
            sourcePath: source.path,
            workingPath: accountFolder.appendingPathComponent("source").path,
            repoName: "source",
            willCopy: true
        )
        let ghChain = GhChain()
        let logStore = LogStore()
        let auth = AuthProcessController()
        let accountManager = AccountManager(ghChain: ghChain, logStore: logStore, authProcessController: auth)
        let repoManager = RepoManager(ghChain: ghChain, logStore: logStore, accountManager: accountManager)
        let workflow = ProjectWorkflow(
            ghChain: ghChain,
            logStore: logStore,
            repoManager: repoManager,
            initAndPushProject: { _, _ in
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                try? "replacement\n".write(to: source.appendingPathComponent("README.md"),
                                            atomically: true,
                                            encoding: .utf8)
                return ShellResult(exitCode: 0, stdout: "pushed", stderr: "")
            },
            refreshReposAfterInit: { _ in }
        )

        let ok = await workflow.initProject(plan,
                                            visibility: .private,
                                            moveOriginalToTrash: true)

        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("README.md")), "replacement\n")
        XCTAssertTrue(logStore.log.contains("changed during initialization"))
    }

    // MARK: - Repo name sanitization warning (#9)

    /// A folder name that sanitizes to something unrecognizable must produce a
    /// warning so the user catches a surprising push target (e.g. all-punctuation
    /// collapsing to "new-repo") before confirming.
    func testRepoNameWarningFlagsUnrecognizableCollapse() {
        XCTAssertNotNil(ProjectInitPlan.repoNameWarning(sourceName: "...---...", sanitizedRepoName: "new-repo"),
                        "a name that collapsed to the fallback must warn")
        XCTAssertNotNil(ProjectInitPlan.repoNameWarning(sourceName: "项目", sanitizedRepoName: "new-repo"),
                        "a name that lost all its characters to sanitization must warn")
    }

    /// A name that sanitizes to something recognizably derived from the source
    /// (shared letters, in order) must NOT warn — normal sanitization (punctuation
    /// → hyphens) is expected and not worth surfacing.
    func testRepoNameWarningNilForRecognizableDerivation() {
        XCTAssertNil(ProjectInitPlan.repoNameWarning(sourceName: "my-cool-app", sanitizedRepoName: "my-cool-app"))
        // Spaces → hyphens: recognizable, no warning.
        XCTAssertNil(ProjectInitPlan.repoNameWarning(sourceName: "my cool app", sanitizedRepoName: "my-cool-app"))
        // Trailing punctuation trimmed: still recognizable.
        XCTAssertNil(ProjectInitPlan.repoNameWarning(sourceName: "app-2024!", sanitizedRepoName: "app-2024"))
        XCTAssertNil(ProjectInitPlan.repoNameWarning(sourceName: "héllo", sanitizedRepoName: "h-llo"),
                     "letter-for-letter (modulo accents) derivation is recognizable")
    }

    /// The warning message references both the original and sanitized names so the
    /// user can see exactly what changed.
    func testRepoNameWarningMessageNamesBothForms() {
        let warning = ProjectInitPlan.repoNameWarning(sourceName: "...---...", sanitizedRepoName: "new-repo")
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("...---...") == true)
        XCTAssertTrue(warning?.contains("new-repo") == true)
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitNestInitProjectTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
