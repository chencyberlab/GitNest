import XCTest
@testable import GitNest

/// The app's central promise is that one account's repo state never bleeds into
/// another's. Two mechanisms enforce it and neither was tested:
///
///  • the per-alias caches + `saveVisibleRepoState`/`restoreRepoState` swap on
///    account switch, and
///  • the `selectedAccount?.alias == owner` guards in `loadRepos`, which keep a
///    background refresh of a *non-visible* account from overwriting the visible
///    list.
///
/// A regression in either is exactly the "data bleed between accounts" the design
/// exists to prevent, so these lock both down. The `loadRepos` paths use an
/// injected list fetch (no network) and non-existent folders (so the clone/status
/// scans resolve to `.absent` without touching real repos).
@MainActor
final class AccountIsolationTests: XCTestCase {
    private func makeManager(
        listRepos: @escaping @Sendable (String) -> Result<[Repo], CommandError> = { _ in .success([]) }
    ) -> (RepoManager, AccountManager) {
        let ghChain = GhChain()
        let logStore = LogStore()
        let accountManager = AccountManager(ghChain: ghChain, logStore: logStore,
                                            authProcessController: AuthProcessController())
        let repoManager = RepoManager(ghChain: ghChain, logStore: logStore,
                                      accountManager: accountManager, listRepos: listRepos)
        return (repoManager, accountManager)
    }

    private func account(_ alias: String) -> Account {
        Account(alias: alias, name: alias, email: "\(alias)@example.com",
                folder: "/tmp/gitnest-isolation-\(alias)-\(UUID().uuidString)")
    }

    private func repo(_ name: String, owner: String) -> Repo {
        Repo(name: name, nameWithOwner: "\(owner)/\(name)", description: nil,
             visibility: "private", updatedAt: "2026-01-01T00:00:00Z",
             url: "https://github.com/\(owner)/\(name)")
    }

    /// Switching away from an account must clear the visible repo list (the new
    /// account hasn't loaded), and switching back must restore the first account's
    /// repos and selection intact from its cache — never the other account's.
    func testSwitchingAccountsSwapsVisibleStateWithoutBleed() {
        let (mgr, accounts) = makeManager()
        let a = account("a")
        let b = account("b")
        accounts.accounts = [a, b]

        // A is selected with its own loaded repos and a selection.
        accounts.selectedAccount = a
        let ra = repo("ra", owner: "a")
        mgr.repos = [ra]
        mgr.clonedRepos = [ra.id]
        mgr.selectedRepo = ra.id

        // --- switch A -> B (the save-then-restore the AppModel switch performs) ---
        mgr.saveVisibleRepoState()             // persists A's state under "a"
        accounts.selectedAccount = b           // direct set: no status-check side effects
        mgr.restoreRepoState(for: b)

        XCTAssertTrue(mgr.repos.isEmpty, "B must not inherit A's visible repos")
        XCTAssertNil(mgr.selectedRepo, "B must not inherit A's selected repo")
        XCTAssertTrue(mgr.clonedRepos.isEmpty, "B must not inherit A's cloned set")

        // --- switch B -> A: A's exact state comes back, not B's empty state ---
        mgr.saveVisibleRepoState()             // persists B's (empty) state under "b"
        accounts.selectedAccount = a
        mgr.restoreRepoState(for: a)

        XCTAssertEqual(mgr.repos.map(\.name), ["ra"])
        XCTAssertEqual(mgr.selectedRepo, ra.id)
        XCTAssertEqual(mgr.clonedRepos, [ra.id])
    }

    /// A background refresh of a NON-visible account must update only that account's
    /// cache, never the visible list. This is the `selectedAccount?.alias == owner`
    /// guard in `loadRepos`; dropping it would splat B's repos over A's open view.
    func testBackgroundLoadOfHiddenAccountDoesNotTouchVisibleList() async {
        let a = account("a")
        let b = account("b")
        let rb = repo("rb", owner: "b")
        let (mgr, accounts) = makeManager(listRepos: { owner in
            owner == "b" ? .success([rb]) : .success([])
        })
        accounts.accounts = [a, b]

        // A is visible with its own repo on screen.
        accounts.selectedAccount = a
        let ra = repo("ra", owner: "a")
        mgr.repos = [ra]

        // Refresh B in the background while A stays selected.
        await mgr.loadRepos(for: b, silent: true, userInitiated: false)

        XCTAssertEqual(mgr.repos.map(\.name), ["ra"],
                       "a hidden account's refresh must not overwrite the visible list")
        XCTAssertEqual(mgr.repoCache["b"]?.map(\.name), ["rb"],
                       "the hidden account's result must land in its own cache")
        XCTAssertNil(mgr.repoCache["a"]?.first,
                     "A was never loaded through loadRepos, so its cache stays empty")
    }

    /// A load that completes for an account the user has since switched AWAY from
    /// must still write that account's cache but must not publish into the now-
    /// visible account's view. Simulates the result landing after a switch.
    func testLoadResultPublishesToCacheNotTheNewlySelectedAccount() async {
        let a = account("a")
        let b = account("b")
        let ra = repo("ra", owner: "a")
        let (mgr, accounts) = makeManager(listRepos: { owner in
            owner == "a" ? .success([ra]) : .success([])
        })
        accounts.accounts = [a, b]

        // Start "as if" A is selected, then flip to B before the load is awaited.
        accounts.selectedAccount = b
        mgr.repos = []   // B's empty visible state

        // The load targets A while B is the selected account.
        await mgr.loadRepos(for: a, silent: true, userInitiated: false)

        XCTAssertTrue(mgr.repos.isEmpty, "A's load must not appear in B's visible list")
        XCTAssertEqual(mgr.repoCache["a"]?.map(\.name), ["ra"],
                       "A's result is still cached for when the user returns to it")
    }
}
