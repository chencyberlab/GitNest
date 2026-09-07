import XCTest
@testable import GitNest

final class RepoAttentionTests: XCTestCase {
    private func status(changed: Int = 0, ahead: Int = 0, behind: Int = 0) -> RepoStatus {
        var status = RepoStatus()
        status.changedFiles = changed
        status.ahead = ahead
        status.behind = behind
        status.remoteState = .checked
        return status
    }

    private func repo(_ name: String) -> Repo {
        Repo(name: name, nameWithOwner: "me/\(name)", description: nil,
             visibility: "private", updatedAt: "2026-01-01T00:00:00Z", url: "")
    }

    func testSummaryCountsEachKindWithoutDoubleCountingDivergedInAheadBehind() {
        let statuses: [Repo.ID: RepoStatus] = [
            "me/dirty": status(changed: 2),
            "me/ahead": status(ahead: 1),
            "me/behind": status(behind: 3),
            "me/diverged": status(ahead: 1, behind: 2),
            "me/dirty-diverged": status(changed: 1, ahead: 1, behind: 1),
        ]
        let cloned: Set<Repo.ID> = Set(statuses.keys)
        let summary = RepoAttention.summary(statuses: statuses, clonedRepos: cloned)

        XCTAssertEqual(summary.dirty, 2)
        XCTAssertEqual(summary.ahead, 1)
        XCTAssertEqual(summary.behind, 1)
        XCTAssertEqual(summary.diverged, 2)
        XCTAssertFalse(summary.isEmpty)
    }

    func testSummaryIgnoresStatusesForReposThatAreNotCloned() {
        let statuses = ["me/ghost": status(changed: 4)]
        let summary = RepoAttention.summary(statuses: statuses, clonedRepos: [])
        XCTAssertTrue(summary.isEmpty)
    }

    func testFilteredReposAppliesAttentionFilter() {
        let repos = [repo("clean"), repo("dirty"), repo("behind")]
        let statuses: [Repo.ID: RepoStatus] = [
            "me/clean": status(),
            "me/dirty": status(changed: 1),
            "me/behind": status(behind: 2),
        ]
        let filtered = RepoManager.filteredRepos(
            query: "",
            repos: repos,
            clonedRepos: Set(repos.map(\.id)),
            sortField: .name,
            sortAscending: true,
            attentionFilter: .dirty,
            statuses: statuses
        )
        XCTAssertEqual(filtered.map(\.name), ["dirty"])
    }

    func testAttentionFilterStacksWithSearch() {
        let repos = [repo("alpha"), repo("beta"), repo("gamma")]
        let statuses: [Repo.ID: RepoStatus] = [
            "me/alpha": status(changed: 1),
            "me/beta": status(changed: 1),
            "me/gamma": status(),
        ]
        let filtered = RepoManager.filteredRepos(
            query: "be",
            repos: repos,
            clonedRepos: Set(repos.map(\.id)),
            sortField: .name,
            sortAscending: true,
            attentionFilter: .dirty,
            statuses: statuses
        )
        XCTAssertEqual(filtered.map(\.name), ["beta"])
    }

    @MainActor
    func testMoveRepoSelectionWrapsAtEndsAndSeedsFromEmpty() {
        let ghChain = GhChain()
        let logStore = LogStore()
        let accounts = AccountManager(ghChain: ghChain, logStore: logStore,
                                      authProcessController: AuthProcessController())
        let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: "/tmp")
        accounts.accounts = [account]
        accounts.selectedAccount = account
        let mgr = RepoManager(ghChain: ghChain, logStore: logStore, accountManager: accounts)
        mgr.repos = [repo("a"), repo("b"), repo("c")]
        mgr.rebuildFilteredRepos()

        mgr.moveRepoSelection(by: 1)
        XCTAssertEqual(mgr.selectedRepo, "me/a")

        mgr.moveRepoSelection(by: 1)
        XCTAssertEqual(mgr.selectedRepo, "me/b")

        mgr.moveRepoSelection(by: 1)
        XCTAssertEqual(mgr.selectedRepo, "me/c")

        mgr.moveRepoSelection(by: 1)
        XCTAssertEqual(mgr.selectedRepo, "me/c", "↓ at the end must stay put")

        mgr.selectedRepo = nil
        mgr.moveRepoSelection(by: -1)
        XCTAssertEqual(mgr.selectedRepo, "me/c", "↑ with no selection lands on the last row")
    }

    @MainActor
    func testToggleAttentionFilterAndEnsureRepoVisibleClearsIt() {
        let ghChain = GhChain()
        let logStore = LogStore()
        let accounts = AccountManager(ghChain: ghChain, logStore: logStore,
                                      authProcessController: AuthProcessController())
        let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: "/tmp")
        accounts.accounts = [account]
        accounts.selectedAccount = account
        let mgr = RepoManager(ghChain: ghChain, logStore: logStore, accountManager: accounts)
        let created = repo("brand-new")

        mgr.toggleAttentionFilter(.dirty)
        XCTAssertEqual(mgr.attentionFilter, .dirty)
        mgr.toggleAttentionFilter(.dirty)
        XCTAssertNil(mgr.attentionFilter)

        mgr.toggleAttentionFilter(.behind)
        mgr.ensureRepoVisible(created, for: account)
        XCTAssertNil(mgr.attentionFilter)
        XCTAssertEqual(mgr.selectedRepo, created.id)
        XCTAssertEqual(mgr.highlightRepoID, created.id)
    }
}
