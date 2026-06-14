import XCTest
@testable import GitNest

final class ForkProjectTests: XCTestCase {
    @MainActor
    func testForkProjectRefusesOccupiedDestinationBeforeCloneOrUpstream() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let occupied = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)

        let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: root.path)
        let forked = Repo(
            name: "repo",
            nameWithOwner: "me/repo",
            description: nil,
            visibility: "public",
            updatedAt: nil,
            url: "https://github.com/me/repo"
        )
        let cloneCalls = LockedCounter()
        let upstreamCalls = LockedCounter()
        let workflow = makeWorkflow(
            forkRepo: { _, _ in .success(ForkOutcome(repo: forked, alreadyExisted: false)) },
            cloneRepo: { _, _ in
                cloneCalls.increment()
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            },
            setUpstream: { _, _ in
                upstreamCalls.increment()
                return ShellResult(exitCode: 0, stdout: "", stderr: "")
            }
        )

        let ok = await workflow.forkProject(source: "source/repo", account: account)

        XCTAssertFalse(ok)
        XCTAssertEqual(cloneCalls.value, 0)
        XCTAssertEqual(upstreamCalls.value, 0)
    }

    @MainActor
    func testForkProjectAcceptsExistingFolderOnlyWhenItIsTheExpectedFork() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repoFolder = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoFolder, withIntermediateDirectories: true)
        XCTAssertTrue(Shell.run(["git", "-C", repoFolder.path, "init"]).ok)
        XCTAssertTrue(Shell.run(["git", "-C", repoFolder.path, "remote", "add", "origin", "https://github.com/me/repo.git"]).ok)

        let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: root.path)
        let forked = Repo(
            name: "repo",
            nameWithOwner: "me/repo",
            description: nil,
            visibility: "public",
            updatedAt: nil,
            url: "https://github.com/me/repo"
        )
        let cloneCalls = LockedCounter()
        let upstreamCalls = LockedCounter()
        let workflow = makeWorkflow(
            forkRepo: { _, _ in .success(ForkOutcome(repo: forked, alreadyExisted: true)) },
            cloneRepo: { _, _ in
                cloneCalls.increment()
                return ShellResult(exitCode: 1, stdout: "", stderr: "should not clone")
            },
            setUpstream: { _, _ in
                upstreamCalls.increment()
                return ShellResult(exitCode: 0, stdout: "upstream set", stderr: "")
            }
        )

        let ok = await workflow.forkProject(source: "source/repo", account: account)

        XCTAssertTrue(ok)
        XCTAssertEqual(cloneCalls.value, 0)
        XCTAssertEqual(upstreamCalls.value, 1)
    }

    func testForkedRepoNameUsesActualCreatedForkFromOutput() {
        let output = "✓ Created fork me/repo-1\nhttps://github.com/me/repo-1"

        XCTAssertEqual(
            GitHub.forkedRepoNameWithOwner(from: output, currentUser: "me", fallbackRepo: "repo"),
            "me/repo-1"
        )
    }

    func testForkedRepoNameIgnoresSourceRepoAndFallsBackWhenAbsent() {
        XCTAssertEqual(
            GitHub.forkedRepoNameWithOwner(
                from: "Forking source/repo into your account...",
                currentUser: "me",
                fallbackRepo: "repo"
            ),
            "me/repo"
        )
    }

    func testForkedRepoNameParsesGitURLWithGitSuffix() {
        XCTAssertEqual(
            GitHub.forkedRepoNameWithOwner(
                from: "remote: https://github.com/me/repo-2.git",
                currentUser: "me",
                fallbackRepo: "repo"
            ),
            "me/repo-2"
        )
    }

    func testForkedRepoNameCandidatesIncludeRenamedForkBeforeFallback() {
        let candidates = GitHub.forkedRepoNameCandidates(
            from: "fork already exists: https://github.com/me/repo-3",
            currentUser: "me",
            fallbackRepo: "repo"
        )

        XCTAssertEqual(candidates, ["me/repo-3", "me/repo"])
    }

    func testRepoViewDetailsVerifiesForkParent() {
        let source = RepoReference(owner: "source", repo: "repo", raw: "source/repo")
        let repo = Repo(
            name: "repo-3",
            nameWithOwner: "me/repo-3",
            description: nil,
            visibility: "public",
            updatedAt: nil,
            url: "https://github.com/me/repo-3"
        )

        XCTAssertTrue(RepoViewDetails(repo: repo, parentNameWithOwner: "source/repo").isFork(of: source))
        XCTAssertTrue(RepoViewDetails(repo: repo, parentNameWithOwner: "SOURCE/REPO").isFork(of: source))
        XCTAssertFalse(RepoViewDetails(repo: repo, parentNameWithOwner: "other/repo").isFork(of: source))
        XCTAssertFalse(RepoViewDetails(repo: repo, parentNameWithOwner: nil).isFork(of: source))
    }

    func testDecodeRepoViewDetailsParsesGitHubForkParentShape() {
        // The exact JSON `gh repo view --json …,parent` emits for a fork: the
        // parent is a nested {name, owner:{login}} object with NO flat
        // `nameWithOwner`. A decoder that required `parent.nameWithOwner` threw,
        // `try?` swallowed it, and every fork looked "not available" for 60s.
        let json = """
        {"name":"awesome-design-md","nameWithOwner":"chencyberlab/awesome-design-md",\
        "parent":{"id":"R_kgDOR2Chew","name":"awesome-design-md",\
        "owner":{"id":"O_kgDOC_9TSg","login":"VoltAgent"}},\
        "url":"https://github.com/chencyberlab/awesome-design-md","visibility":"PUBLIC"}
        """

        let details = GitHub.decodeRepoViewDetails(fromJSON: json)
        XCTAssertNotNil(details, "fork payload must decode")
        XCTAssertEqual(details?.repo.nameWithOwner, "chencyberlab/awesome-design-md")
        XCTAssertEqual(details?.parentNameWithOwner, "VoltAgent/awesome-design-md")

        let source = RepoReference(owner: "VoltAgent", repo: "awesome-design-md",
                                   raw: "VoltAgent/awesome-design-md")
        XCTAssertEqual(details?.isFork(of: source), true)
    }

    func testDecodeRepoViewDetailsParsesNonForkWithNullParent() {
        let json = """
        {"name":"GitNest","nameWithOwner":"chencyberlab/GitNest","parent":null,\
        "url":"https://github.com/chencyberlab/GitNest","visibility":"PUBLIC"}
        """

        let details = GitHub.decodeRepoViewDetails(fromJSON: json)
        XCTAssertNotNil(details)
        XCTAssertNil(details?.parentNameWithOwner)
    }

    func testRepoReferenceParsesHTTPSURL() {
        let ref = RepoReference.parse("https://github.com/owner/repo")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
        XCTAssertEqual(ref?.nameWithOwner, "owner/repo")
    }

    func testRepoReferenceParsesHTTPSURLWithGitSuffix() {
        let ref = RepoReference.parse("https://github.com/owner/repo.git")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    func testRepoReferenceParsesHTTPSURLWithTrailingSlash() {
        let ref = RepoReference.parse("https://github.com/owner/repo/")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    func testRepoReferenceParsesHTTPURL() {
        let ref = RepoReference.parse("http://github.com/owner/repo")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    func testRepoReferenceParsesBareGitHubHost() {
        let ref = RepoReference.parse("github.com/owner/repo")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    func testRepoReferenceParsesSSHForm() {
        let ref = RepoReference.parse("git@github.com:owner/repo.git")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    func testRepoReferenceParsesOwnerRepoShorthand() {
        let ref = RepoReference.parse("owner/repo")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    func testRepoReferenceAllowsValidRepoPunctuation() {
        let ref = RepoReference.parse("owner/repo--name_1.2")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo--name_1.2")
    }

    func testRepoReferenceRejectsEmptyInput() {
        XCTAssertNil(RepoReference.parse(""))
        XCTAssertNil(RepoReference.parse("   "))
    }

    func testRepoReferenceRejectsMissingOwnerOrRepo() {
        XCTAssertNil(RepoReference.parse("repo"))
        XCTAssertNil(RepoReference.parse("/repo"))
        XCTAssertNil(RepoReference.parse("owner/"))
    }

    func testRepoReferenceRejectsGitHubPageURLs() {
        XCTAssertNil(RepoReference.parse("https://github.com/owner/repo/tree/main"))
        XCTAssertNil(RepoReference.parse("https://github.com/owner/repo/issues/1"))
        XCTAssertNil(RepoReference.parse("https://github.com/owner/repo/pull/1"))
    }

    func testRepoReferenceRejectsNonGitHubHost() {
        XCTAssertNil(RepoReference.parse("https://gitlab.com/owner/repo"))
        XCTAssertNil(RepoReference.parse("git@gitlab.com:owner/repo.git"))
    }

    func testRepoReferenceRejectsInvalidOwnerNames() {
        XCTAssertNil(RepoReference.parse("bad_owner/repo"))
        XCTAssertNil(RepoReference.parse("-owner/repo"))
        XCTAssertNil(RepoReference.parse("owner-/repo"))
        XCTAssertNil(RepoReference.parse("owner--name/repo"))
    }

    func testRepoReferenceRejectsInvalidRepoNames() {
        XCTAssertNil(RepoReference.parse("owner/Repo Name"))
        XCTAssertNil(RepoReference.parse("owner/."))
        XCTAssertNil(RepoReference.parse("owner/.."))
    }

    func testRepoReferenceTrimsWhitespace() {
        let ref = RepoReference.parse("  https://github.com/owner/repo  ")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    @MainActor
    private func makeWorkflow(
        forkRepo: @escaping @Sendable (RepoReference, String) -> Result<ForkOutcome, CommandError>,
        cloneRepo: @escaping @Sendable (Repo, String) -> ShellResult,
        setUpstream: @escaping @Sendable (RepoReference, String) -> ShellResult
    ) -> ProjectWorkflow {
        let ghChain = GhChain()
        let logStore = LogStore()
        let auth = AuthProcessController()
        let accountManager = AccountManager(ghChain: ghChain, logStore: logStore, authProcessController: auth)
        let repoManager = RepoManager(ghChain: ghChain, logStore: logStore, accountManager: accountManager)
        return ProjectWorkflow(ghChain: ghChain,
                               logStore: logStore,
                               repoManager: repoManager,
                               forkRepo: forkRepo,
                               cloneRepo: cloneRepo,
                               setUpstream: setUpstream,
                               refreshReposAfterFork: { _ in })
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitNestForkProjectTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
