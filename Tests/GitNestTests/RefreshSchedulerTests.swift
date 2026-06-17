import XCTest
@testable import GitNest

/// Covers the auto-refresh scheduler math the README documents but nothing tested:
/// `effectiveRefreshInterval = base × ceil(repoCount / 500)`, the 5-minute
/// background floor, and the visible-vs-background base. These are the constants
/// that keep GitNest within GitHub's per-account API budget, so a silent regression
/// here (e.g. background accounts polling every 30s) would matter.
@MainActor
final class RefreshSchedulerTests: XCTestCase {
    private func makeManager(
        listRepos: (@Sendable (String) -> Result<[Repo], CommandError>)? = nil
    ) -> (RepoManager, AccountManager) {
        let logStore = LogStore()
        let ghChain = GhChain()
        let accountManager = AccountManager(ghChain: ghChain,
                                            logStore: logStore,
                                            authProcessController: AuthProcessController())
        let repoManager: RepoManager
        if let listRepos {
            repoManager = RepoManager(ghChain: ghChain, logStore: logStore,
                                      accountManager: accountManager, listRepos: listRepos)
        } else {
            repoManager = RepoManager(ghChain: ghChain, logStore: logStore, accountManager: accountManager)
        }
        return (repoManager, accountManager)
    }

    private func account(_ alias: String) -> Account {
        Account(alias: alias, name: alias, email: "\(alias)@example.com", folder: "/\(alias)")
    }

    private func repos(_ count: Int) -> [Repo] {
        (0..<count).map { i in
            Repo(name: "r\(i)", nameWithOwner: "owner/r\(i)", description: nil,
                 visibility: "public", updatedAt: nil, url: "https://example.com/r\(i)")
        }
    }

    func testIntervalIsZeroWhenAutoRefreshOff() {
        let (repo, accounts) = makeManager()
        accounts.selectedAccount = account("vis")
        repo.repoAutoRefreshSeconds = 0
        XCTAssertEqual(repo.effectiveRefreshInterval(for: "vis"), 0)
        XCTAssertEqual(repo.effectiveRefreshInterval(for: "bg"), 0)
        // interval == 0 means "never due".
        XCTAssertFalse(repo.shouldAutoRefreshRepos(for: "vis"))
    }

    func testVisibleAccountHonorsChosenInterval() {
        let (repo, accounts) = makeManager()
        accounts.selectedAccount = account("vis")
        repo.repoAutoRefreshSeconds = 30
        repo.repoCache["vis"] = repos(100)   // ≤ 500 → ×1
        XCTAssertEqual(repo.effectiveRefreshInterval(for: "vis"), 30)
    }

    func testBackgroundAccountIsFlooredToFiveMinutes() {
        let (repo, accounts) = makeManager()
        accounts.selectedAccount = account("vis")
        repo.repoAutoRefreshSeconds = 30      // a short interval...
        repo.repoCache["bg"] = repos(100)
        // ...still floors a non-visible account to 5 minutes, so adding accounts
        // never multiplies background traffic.
        XCTAssertEqual(repo.effectiveRefreshInterval(for: "bg"), RepoManager.backgroundRefreshFloorSeconds)
        XCTAssertEqual(RepoManager.backgroundRefreshFloorSeconds, 300)
    }

    func testSizeBackoffIsCeilingPer500Repos() {
        let (repo, accounts) = makeManager()
        accounts.selectedAccount = account("vis")
        repo.repoAutoRefreshSeconds = 30

        // Exact 500 stays ×1; one over rolls to ×2 (true ceil, not floor).
        repo.repoCache["vis"] = repos(500)
        XCTAssertEqual(repo.effectiveRefreshInterval(for: "vis"), 30, "500 repos → ×1")
        repo.repoCache["vis"] = repos(501)
        XCTAssertEqual(repo.effectiveRefreshInterval(for: "vis"), 60, "501 repos → ×2")
        repo.repoCache["vis"] = repos(1000)
        XCTAssertEqual(repo.effectiveRefreshInterval(for: "vis"), 60, "1000 repos → ×2")
        repo.repoCache["vis"] = repos(1001)
        XCTAssertEqual(repo.effectiveRefreshInterval(for: "vis"), 90, "1001 repos → ×3")
    }

    func testFloorAndBackoffStack() {
        let (repo, accounts) = makeManager()
        accounts.selectedAccount = account("vis")
        repo.repoAutoRefreshSeconds = 30
        repo.repoCache["bg"] = repos(800)   // background floor 300 × ceil(800/500)=2
        XCTAssertEqual(repo.effectiveRefreshInterval(for: "bg"), 600)
    }

    func testDueWhenNeverRefreshedAndNotDueRightAfterRefresh() {
        let (repo, accounts) = makeManager()
        accounts.selectedAccount = account("vis")
        repo.repoAutoRefreshSeconds = 30
        repo.repoCache["vis"] = repos(10)

        // No recorded refresh → due immediately.
        XCTAssertTrue(repo.shouldAutoRefreshRepos(for: "vis"))

        // Just refreshed → not due until the interval elapses.
        repo.repoLastRefreshAt["vis"] = Date()
        XCTAssertFalse(repo.shouldAutoRefreshRepos(for: "vis"))

        // A refresh older than the interval → due again.
        repo.repoLastRefreshAt["vis"] = Date().addingTimeInterval(-31)
        XCTAssertTrue(repo.shouldAutoRefreshRepos(for: "vis"))
    }

    func testRateLimitSuppressesShouldAutoRefreshRepos() {
        GitHub.clearRateLimitBackoff()
        defer { GitHub.clearRateLimitBackoff() }

        let (repo, accounts) = makeManager()
        accounts.selectedAccount = account("vis")
        repo.repoAutoRefreshSeconds = 30
        repo.repoCache["vis"] = repos(10)
        XCTAssertTrue(repo.shouldAutoRefreshRepos(for: "vis"))

        GitHub.recordRateLimitBackoff(owner: "vis", seconds: 60)
        XCTAssertFalse(repo.shouldAutoRefreshRepos(for: "vis"))
        XCTAssertTrue(repo.shouldAutoRefreshRepos(for: "other"))
    }

    /// A *successful* `loadRepos` stamps `repoLastRefreshAt`, so the account is no
    /// longer due until its interval elapses. Drives the real success branch of
    /// `loadRepos` (via the injected list fetch) rather than setting the timestamp
    /// by hand, so it would catch a regression that stopped stamping on success.
    func testSuccessfulRefreshStampsLastRefreshAt() async {
        let acct = account("vis")
        let (repo, accounts) = makeManager(listRepos: { _ in .success([]) })
        accounts.accounts = [acct]
        accounts.selectedAccount = acct
        repo.repoAutoRefreshSeconds = 30

        XCTAssertNil(repo.repoLastRefreshAt["vis"], "no refresh recorded before the first load")

        await repo.loadRepos(for: acct)

        XCTAssertNotNil(repo.repoLastRefreshAt["vis"], "a successful load must record the refresh time")
        XCTAssertFalse(repo.shouldAutoRefreshRepos(for: "vis"),
                       "just refreshed ⇒ not due until the interval elapses")
    }

    /// A *failed* `loadRepos` must NOT stamp `repoLastRefreshAt`, so the account
    /// stays due and the next tick retries promptly instead of waiting out the full
    /// interval. Drives the real failure branch through the injected fetch — the
    /// previous version of this test deleted the timestamp by hand, so it passed
    /// even when `loadRepos` stamped unconditionally; this one fails if the stamp
    /// moves back out of the `.success` case.
    func testFailedRefreshDoesNotStampLastRefreshAt() async {
        let acct = account("vis")
        let (repo, accounts) = makeManager(
            listRepos: { _ in .failure(CommandError(message: "simulated network blip")) }
        )
        accounts.accounts = [acct]
        accounts.selectedAccount = acct
        repo.repoAutoRefreshSeconds = 30

        await repo.loadRepos(for: acct)

        XCTAssertNil(repo.repoLastRefreshAt["vis"],
                     "a failed load must not record a refresh time")
        XCTAssertTrue(repo.shouldAutoRefreshRepos(for: "vis"),
                      "a failed refresh must leave the account due for the next tick")
    }

    func testLocalStatusRefreshPreservesRemoteFailureUntilLiveCheckSucceeds() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repoFolder = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: repoFolder, withIntermediateDirectories: true)
        XCTAssertTrue(Shell.run(["git", "init"], cwd: repoFolder.path).ok)
        XCTAssertTrue(Shell.run(["git", "checkout", "-B", "main"], cwd: repoFolder.path).ok)
        XCTAssertTrue(Shell.run(["git", "config", "user.name", "Test User"], cwd: repoFolder.path).ok)
        XCTAssertTrue(Shell.run(["git", "config", "user.email", "test@example.com"], cwd: repoFolder.path).ok)
        try "hello\n".write(to: repoFolder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(Shell.run(["git", "add", "README.md"], cwd: repoFolder.path).ok)
        XCTAssertTrue(Shell.run(["git", "commit", "-m", "Initial"], cwd: repoFolder.path).ok)
        XCTAssertTrue(Shell.run([
            "git", "remote", "add", "origin", "https://github.com/me/tools.git"
        ], cwd: repoFolder.path).ok)
        XCTAssertTrue(Shell.run([
            "git", "update-ref", "refs/remotes/origin/main", "HEAD"
        ], cwd: repoFolder.path).ok)
        XCTAssertTrue(Shell.run([
            "git", "branch", "--set-upstream-to=origin/main", "main"
        ], cwd: repoFolder.path).ok)

        let (manager, accounts) = makeManager()
        let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: root.path)
        let target = Repo(name: "tools",
                          nameWithOwner: "me/tools",
                          description: nil,
                          visibility: "private",
                          updatedAt: nil,
                          url: "https://github.com/me/tools")
        accounts.selectedAccount = account
        manager.repos = [target]
        manager.clonedRepos = [target.id]
        var previous = RepoStatus()
        previous.hasUpstream = true
        previous.upstreamRef = "origin/main"
        previous.remoteState = .failed("fetch failed")
        manager.repoStatuses = [target.id: previous]

        await manager.refreshStatuses(for: account)

        XCTAssertEqual(manager.repoStatuses[target.id]?.remoteState, .failed("fetch failed"))
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitNestRefreshSchedulerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
