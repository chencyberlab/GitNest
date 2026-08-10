import XCTest
@testable import GitNest

/// Pins the per-folder busy-state serialization the row buttons and destructive
/// guards depend on. These properties were previously untested through the
/// coordinator — only the lower-level `busyPathKey` folding was covered — so a
/// regression in `beginRepoAction`/`finishRepoAction` (e.g. a path that let two
/// actions collide on the same folder) could land silently. The coordinator's
/// mutating repo actions all funnel through `begin`/`finish`, so locking these
/// primitives down locks the whole action surface.
@MainActor
final class RepoActionCoordinatorTests: XCTestCase {
    private final class LockedDiffCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshotPaths: [String] = []
        private var diffPaths: [String] = []

        func recordSnapshot(_ path: String) {
            lock.lock()
            snapshotPaths.append(path)
            lock.unlock()
        }

        func recordDiff(_ path: String) {
            lock.lock()
            diffPaths.append(path)
            lock.unlock()
        }

        func counts() -> (snapshot: Int, diff: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (snapshotPaths.count, diffPaths.count)
        }
    }

    private func makeCoordinator(repos: [Repo], account: Account) -> RepoActionCoordinator {
        let ghChain = GhChain()
        let logStore = LogStore()
        let auth = AuthProcessController()
        let accountManager = AccountManager(ghChain: ghChain, logStore: logStore, authProcessController: auth)
        accountManager.accounts = [account]
        accountManager.selectedAccount = account
        let repoManager = RepoManager(ghChain: ghChain, logStore: logStore, accountManager: accountManager)
        repoManager.repos = repos
        return RepoActionCoordinator(repoManager: repoManager,
                                     logStore: logStore,
                                     alertStore: AlertStore(),
                                     accountManager: accountManager)
    }

    private let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: "/tmp/gitnest-me")

    private func repo(_ name: String, owner: String = "me") -> Repo {
        Repo(name: name, nameWithOwner: "\(owner)/\(name)", description: nil,
             visibility: "private", updatedAt: nil, url: "https://github.com/\(owner)/\(name)")
    }

    /// A second `beginRepoAction` for a repo whose action is already in flight
    /// must be refused (returns nil) — the row's buttons rely on this so two git
    /// processes never collide on the same local folder.
    func testBeginRepoActionRefusesConcurrentActionOnSameRepo() {
        let r = repo("tools")
        let coordinator = makeCoordinator(repos: [r], account: account)

        let first = coordinator.beginRepoAction(r)
        XCTAssertNotNil(first)
        XCTAssertTrue(coordinator.isRepoActionBusy(r))

        // A second begin while the first is outstanding is refused.
        XCTAssertNil(coordinator.beginRepoAction(r))

        coordinator.finishRepoAction(first!)
        XCTAssertFalse(coordinator.isRepoActionBusy(r))

        // After finish, a new action is allowed again.
        let again = coordinator.beginRepoAction(r)
        XCTAssertNotNil(again)
        coordinator.finishRepoAction(again!)
    }

    /// Two repos with different local folders must each be busyable independently —
    /// the serialization is per-folder, not global.
    func testBeginRepoActionAllowsConcurrentActionsOnDifferentFolders() {
        let a = repo("alpha")
        let b = repo("beta")
        let coordinator = makeCoordinator(repos: [a, b], account: account)

        let first = coordinator.beginRepoAction(a)
        XCTAssertNotNil(first)

        // A different repo (different folder) is not blocked by the first.
        let second = coordinator.beginRepoAction(b)
        XCTAssertNotNil(second)

        XCTAssertTrue(coordinator.isRepoActionBusy(a))
        XCTAssertTrue(coordinator.isRepoActionBusy(b))

        coordinator.finishRepoAction(first!)
        XCTAssertTrue(coordinator.isRepoActionBusy(b))
        XCTAssertFalse(coordinator.isRepoActionBusy(a))

        coordinator.finishRepoAction(second!)
    }

    /// `beginRepoAction` requires an account (explicit or selected). With neither,
    /// it must refuse rather than proceed with a nil account.
    func testBeginRepoActionRefusesWithoutAccount() {
        let r = repo("tools")
        let ghChain = GhChain()
        let logStore = LogStore()
        let accountManager = AccountManager(ghChain: ghChain,
                                            logStore: logStore,
                                            authProcessController: AuthProcessController())
        // No accounts, no selected account.
        let repoManager = RepoManager(ghChain: ghChain, logStore: logStore, accountManager: accountManager)
        let coordinator = RepoActionCoordinator(repoManager: repoManager,
                                                logStore: logStore,
                                                alertStore: AlertStore(),
                                                accountManager: accountManager)

        XCTAssertNil(coordinator.beginRepoAction(r))
        XCTAssertFalse(coordinator.isRepoActionBusy(r))
    }

    /// An action for an account that has since been removed (e.g. the user deleted
    /// it while a sheet was open) must be refused — the explicit-account path is
    /// re-validated against the configured accounts at action time.
    func testBeginRepoActionRefusesStaleAccount() {
        let r = repo("tools")
        let coordinator = makeCoordinator(repos: [r], account: account)
        let removed = Account(alias: "ghost", name: "Ghost", email: "g@example.com", folder: "/tmp/gitnest-ghost")

        // `ghost` is not in the configured accounts list.
        XCTAssertNil(coordinator.beginRepoAction(r, in: removed))
        XCTAssertFalse(coordinator.isRepoActionBusy(r))
    }

    /// The read-only diff orchestration must use its injected domain closures so it
    /// remains testable without touching a real repository or spawning Git.
    func testWorkingDiffUsesInjectedLoaders() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("gitnest-diff-coordinator-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: directory.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let file = GitFileChange(path: "work.swift", originalPath: nil, status: .modified)
        let snapshot = GitWorkingTreeSnapshot(base: .head("abc123"), files: [file])
        let expectedDiff = GitFileDiff(additions: 1, deletions: 0, content: .noLineChanges)
        let calls = LockedDiffCalls()
        let ghChain = GhChain()
        let logStore = LogStore()
        let accountManager = AccountManager(
            ghChain: ghChain,
            logStore: logStore,
            authProcessController: AuthProcessController())
        let repoManager = RepoManager(ghChain: ghChain, logStore: logStore, accountManager: accountManager)
        let coordinator = RepoActionCoordinator(
            repoManager: repoManager,
            logStore: logStore,
            alertStore: AlertStore(),
            accountManager: accountManager,
            loadWorkingTreeChanges: { path in
                calls.recordSnapshot(path)
                return .success(snapshot)
            },
            loadWorkingFileDiff: { path, _, _ in
                calls.recordDiff(path)
                return .success(expectedDiff)
            }
        )
        let target = WorkingDiffTarget(
            repoName: "tools",
            nameWithOwner: "me/tools",
            accountAlias: "me",
            localPath: directory.path)

        guard case .success(let loadedSnapshot) = await coordinator.workingTreeChanges(for: target) else {
            return XCTFail("snapshot loader was not used")
        }
        guard
            case .success(let loadedDiff) = await coordinator.workingFileDiff(
                for: target,
                file: file,
                base: loadedSnapshot.base)
        else {
            return XCTFail("diff loader was not used")
        }
        XCTAssertEqual(loadedSnapshot.files.map(\.path), ["work.swift"])
        XCTAssertEqual(loadedDiff, expectedDiff)
        XCTAssertEqual(calls.counts().snapshot, 1)
        XCTAssertEqual(calls.counts().diff, 1)
    }

    func testWorkingDiffSearchUsesInjectedLoaderAndFindsChangedCode() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("gitnest-diff-search-coordinator-\(UUID().uuidString)")
        try fileManager.createDirectory(
            at: directory.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let files = [
            GitFileChange(path: "Sources/App.swift", originalPath: nil, status: .modified),
            GitFileChange(path: "README.md", originalPath: nil, status: .modified),
        ]
        let snapshot = GitWorkingTreeSnapshot(base: .head("abc123"), files: files)
        let calls = LockedDiffCalls()
        let ghChain = GhChain()
        let logStore = LogStore()
        let accountManager = AccountManager(
            ghChain: ghChain,
            logStore: logStore,
            authProcessController: AuthProcessController())
        let repoManager = RepoManager(
            ghChain: ghChain,
            logStore: logStore,
            accountManager: accountManager)
        let coordinator = RepoActionCoordinator(
            repoManager: repoManager,
            logStore: logStore,
            alertStore: AlertStore(),
            accountManager: accountManager,
            loadWorkingFileDiff: { path, file, _ in
                calls.recordDiff(path)
                let patch = "@@ -1 +1 @@\n-old\n+searchable \(file.path)\n"
                return .success(GitDiffParser.parse(unifiedPatch: patch))
            })
        let target = WorkingDiffTarget(
            repoName: "tools",
            nameWithOwner: "me/tools",
            accountAlias: "me",
            localPath: directory.path)

        guard
            case .success(let index) = await coordinator.workingDiffSearchIndex(
                for: target,
                snapshot: snapshot)
        else {
            return XCTFail("search index loader failed")
        }
        let matches = await coordinator.workingDiffSearchMatches(query: "searchable app", index: index)

        XCTAssertEqual(calls.counts().diff, 2)
        XCTAssertEqual(index.files.count, 2)
        XCTAssertEqual(matches.code.map(\.file.path), ["Sources/App.swift"])
        XCTAssertEqual(matches.code.first?.line.newLineNumber, 1)
    }

    func testWorkingDiffRefusesMissingCloneBeforeCallingLoader() async {
        let calls = LockedDiffCalls()
        let ghChain = GhChain()
        let logStore = LogStore()
        let accountManager = AccountManager(ghChain: ghChain,
                                            logStore: logStore,
                                            authProcessController: AuthProcessController())
        let repoManager = RepoManager(ghChain: ghChain, logStore: logStore, accountManager: accountManager)
        let coordinator = RepoActionCoordinator(
            repoManager: repoManager,
            logStore: logStore,
            alertStore: AlertStore(),
            accountManager: accountManager,
            loadWorkingTreeChanges: { path in
                calls.recordSnapshot(path)
                return .success(GitWorkingTreeSnapshot(base: .emptyRepository, files: []))
            }
        )
        let target = WorkingDiffTarget(repoName: "missing",
                                       nameWithOwner: "me/missing",
                                       accountAlias: "me",
                                       localPath: "/tmp/gitnest-definitely-missing-diff-clone")

        guard case .failure(let error) = await coordinator.workingTreeChanges(for: target) else {
            return XCTFail("missing clone should fail")
        }
        XCTAssertTrue(error.message.contains("isn't cloned"))
        XCTAssertEqual(calls.counts().snapshot, 0)
    }

    // MARK: safeGitHubURL (R1 — don't open a remote-supplied non-web URL)

    /// A normal API `html_url` is accepted unchanged so "Open on GitHub" still works.
    func testSafeGitHubURLAcceptsNormalRepoURL() {
        let url = RepoActionCoordinator.safeGitHubURL("https://github.com/octocat/Hello-World")
        XCTAssertEqual(url?.absoluteString, "https://github.com/octocat/Hello-World")
    }

    /// github.com subdomains (e.g. Pages) are still GitHub-owned and allowed.
    func testSafeGitHubURLAcceptsGitHubSubdomain() {
        XCTAssertNotNil(RepoActionCoordinator.safeGitHubURL("https://gist.github.com/octocat/abc123"))
    }

    /// The whole point: a crafted `html_url` carrying a non-https / non-github scheme
    /// must be rejected so it never reaches NSWorkspace.open, which honors any scheme.
    func testSafeGitHubURLRejectsDangerousSchemesAndForeignHosts() {
        XCTAssertNil(RepoActionCoordinator.safeGitHubURL("javascript:alert(1)"))
        XCTAssertNil(RepoActionCoordinator.safeGitHubURL("file:///etc/passwd"))
        XCTAssertNil(RepoActionCoordinator.safeGitHubURL("http://github.com/o/r"))          // not https
        XCTAssertNil(RepoActionCoordinator.safeGitHubURL("https://evil.com/o/r"))
        XCTAssertNil(RepoActionCoordinator.safeGitHubURL("https://github.com.evil.com/o/r")) // suffix-spoof
        XCTAssertNil(RepoActionCoordinator.safeGitHubURL("https://notgithub.com/o/r"))
        XCTAssertNil(RepoActionCoordinator.safeGitHubURL("not a url at all"))
        XCTAssertNil(RepoActionCoordinator.safeGitHubURL(""))
    }
}
