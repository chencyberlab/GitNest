import XCTest
@testable import GitNest

/// Covers the auto-refresh scheduler math the README documents but nothing tested:
/// `effectiveRefreshInterval = base × ceil(repoCount / 500)`, the 5-minute
/// background floor, and the visible-vs-background base. These are the constants
/// that keep GitNest within GitHub's per-account API budget, so a silent regression
/// here (e.g. background accounts polling every 30s) would matter.
@MainActor
final class RefreshSchedulerTests: XCTestCase {
    private func makeManager() -> (RepoManager, AccountManager) {
        let logStore = LogStore()
        let ghChain = GhChain()
        let accountManager = AccountManager(ghChain: ghChain,
                                            logStore: logStore,
                                            authProcessController: AuthProcessController())
        let repoManager = RepoManager(ghChain: ghChain, logStore: logStore, accountManager: accountManager)
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

        GitHub.recordRateLimitBackoff(seconds: 60)
        XCTAssertFalse(repo.shouldAutoRefreshRepos(for: "vis"))
    }
}
