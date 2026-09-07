import XCTest
@testable import GitNest

/// Locks down the post-init "repo never appeared until restart" race: a
/// `loadRepos` that arrives while another is in flight must queue a follow-up
/// pass and still await a fresh list, instead of returning as a silent no-op.
@MainActor
final class RepoLoadCoalesceTests: XCTestCase {
    private final class LockedGate: @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private var releaseFirst = false
        private var firstEntered = false

        func beginCall() -> Int {
            lock.lock()
            callCount += 1
            let n = callCount
            if n == 1 {
                firstEntered = true
                while !releaseFirst {
                    lock.unlock()
                    Thread.sleep(forTimeInterval: 0.01)
                    lock.lock()
                }
            }
            lock.unlock()
            return n
        }

        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return callCount
        }

        var hasEnteredFirst: Bool {
            lock.lock(); defer { lock.unlock() }
            return firstEntered
        }

        func release() {
            lock.lock()
            releaseFirst = true
            lock.unlock()
        }
    }

    private func makeManager(
        listRepos: @escaping @Sendable (String) -> Result<[Repo], CommandError>
    ) -> (RepoManager, AccountManager, Account) {
        let ghChain = GhChain()
        let logStore = LogStore()
        let accountManager = AccountManager(ghChain: ghChain, logStore: logStore,
                                            authProcessController: AuthProcessController())
        let account = Account(alias: "me", name: "Me", email: "me@example.com",
                              folder: "/tmp/gitnest-coalesce-\(UUID().uuidString)")
        accountManager.accounts = [account]
        accountManager.selectedAccount = account
        let repoManager = RepoManager(ghChain: ghChain, logStore: logStore,
                                      accountManager: accountManager, listRepos: listRepos)
        return (repoManager, accountManager, account)
    }

    private func repo(_ name: String) -> Repo {
        Repo(name: name, nameWithOwner: "me/\(name)", description: nil,
             visibility: "private", updatedAt: "2026-01-01T00:00:00Z",
             url: "https://github.com/me/\(name)")
    }

    func testOverlappingLoadReposRunsFollowUpPassInsteadOfDropping() async throws {
        let gate = LockedGate()
        let stale = repo("old")
        let fresh = repo("new")
        let (mgr, _, account) = makeManager { _ in
            let n = gate.beginCall()
            return .success(n == 1 ? [stale] : [stale, fresh])
        }

        let first = Task { await mgr.loadRepos(for: account) }

        var spins = 0
        while !gate.hasEnteredFirst && spins < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            spins += 1
        }
        XCTAssertTrue(gate.hasEnteredFirst, "first list fetch should have started")

        let second = Task { await mgr.loadRepos(for: account, silent: true, userInitiated: true) }
        // Let the second call observe in-flight and register a pending reload.
        try await Task.sleep(nanoseconds: 30_000_000)
        gate.release()

        await first.value
        await second.value

        XCTAssertEqual(gate.calls, 2, "pending reload must trigger a second list fetch")
        XCTAssertEqual(Set(mgr.repos.map(\.name)), ["old", "new"],
                       "the follow-up pass's list must become visible")
        XCTAssertFalse(mgr.repoLoadsInFlight.contains("me"))
    }

    func testEnsureRepoVisibleSurvivesStaleListReplace() {
        let (mgr, _, account) = makeManager { _ in .success([]) }
        let created = repo("brand-new")
        mgr.repos = [repo("other")]
        mgr.repoCache["me"] = mgr.repos
        mgr.repoSearch = "other"

        mgr.ensureRepoVisible(created, for: account)
        XCTAssertTrue(mgr.repos.contains(where: { $0.id == created.id }))
        XCTAssertEqual(mgr.selectedRepo, created.id)
        XCTAssertTrue(mgr.repoSearch.isEmpty, "search that hides the new repo must clear")

        // Simulate a list refresh that still lags behind create.
        mgr.repos = [repo("other")]
        mgr.repoCache["me"] = mgr.repos
        mgr.ensureRepoVisible(created, for: account)

        XCTAssertTrue(mgr.repos.contains(where: { $0.id == created.id }),
                      "re-ensure must put the created repo back after a stale list wipe")
    }

    func testIsBusyWithVisibleRepoLoadIncludesRemoteStatusPass() {
        let (mgr, _, _) = makeManager { _ in .success([]) }
        XCTAssertFalse(mgr.isBusyWithVisibleRepoLoad)

        mgr.isLoadingRepos = true
        XCTAssertTrue(mgr.isBusyWithVisibleRepoLoad)
        mgr.isLoadingRepos = false

        mgr.isRefreshingRepos = true
        XCTAssertTrue(mgr.isBusyWithVisibleRepoLoad)
        mgr.isRefreshingRepos = false

        mgr.isCheckingRepoRemotes = true
        XCTAssertTrue(mgr.isBusyWithVisibleRepoLoad)
    }
}
