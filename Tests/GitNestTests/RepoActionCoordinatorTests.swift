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
}
