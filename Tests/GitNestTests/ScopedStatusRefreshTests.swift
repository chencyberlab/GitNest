import XCTest
@testable import GitNest

/// Free function, not a method: the injected probe closures run off the main actor
/// inside `runBlocking`, so a `@MainActor` helper would be unreachable from them.
private func makeStatus(changed: Int, remote: RepoRemoteState) -> RepoStatus {
    var status = RepoStatus()
    status.changedFiles = changed
    status.remoteState = remote
    return status
}

/// Pins the single-repo status probe that repo actions use instead of the
/// account-wide sweep. The sweep re-fetched every clone in the account after any
/// action, so pushing one repo cost N sequential network round trips and left the
/// row disabled for all of them. These tests lock in the two properties that make
/// scoping safe: exactly one clone is probed, and every sibling keeps the verdict
/// it already had.
@MainActor
final class ScopedStatusRefreshTests: XCTestCase {
    /// Records which paths the injected probe was asked about. Locked because the
    /// probe runs off the main actor inside `runBlocking`.
    private final class ProbedPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ path: String) {
            lock.lock()
            paths.append(path)
            lock.unlock()
        }

        func all() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    /// Lock-guarded flag the async test body can poll — `DispatchSemaphore.wait`
    /// is unavailable from async contexts.
    private final class AtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let account = Account(alias: "me", name: "Me", email: "me@example.com", folder: "/tmp/gitnest-me")

    private func repo(_ name: String) -> Repo {
        Repo(name: name, nameWithOwner: "me/\(name)", description: nil,
             visibility: "private", updatedAt: nil, url: "https://github.com/me/\(name)")
    }

    private func makeManager(
        repoStatus: @escaping @Sendable (String, Bool) -> RepoStatus?
    ) -> (RepoManager, AccountManager) {
        let logStore = LogStore()
        let ghChain = GhChain()
        let accountManager = AccountManager(ghChain: ghChain,
                                            logStore: logStore,
                                            authProcessController: AuthProcessController())
        accountManager.accounts = [account]
        accountManager.selectedAccount = account
        let repoManager = RepoManager(ghChain: ghChain,
                                      logStore: logStore,
                                      accountManager: accountManager,
                                      repoStatus: repoStatus)
        return (repoManager, accountManager)
    }

    /// The whole point of the change: the scoped path shells out for exactly one
    /// clone, however many siblings the account holds. (Which call sites *use* it is
    /// not observable from here — `push`/`pull`/`fetch` shell out to real git and
    /// take no injection seam — so that coupling is held by the call sites
    /// themselves, not by this test.)
    func testScopedRefreshProbesOnlyTheActedRepo() async {
        let probed = ProbedPaths()
        let target = repo("tools")
        let siblings = [repo("api"), repo("web")]
        let (manager, _) = makeManager(repoStatus: { path, _ in
            probed.record(path)
            return RepoStatus()
        })
        manager.repos = [target] + siblings
        manager.clonedRepos = Set(([target] + siblings).map(\.id))

        await manager.refreshStatus(for: target, in: account, refreshRemote: true)

        XCTAssertEqual(probed.all(), ["/tmp/gitnest-me/tools"],
                       "a repo action must fetch only the repo it acted on")
    }

    /// Siblings keep the verdict from their last live fetch — that carry-forward is
    /// what makes scoping safe rather than a correctness regression.
    func testScopedRefreshLeavesSiblingStatusesUntouched() async {
        let target = repo("tools")
        let sibling = repo("api")
        let (manager, _) = makeManager(repoStatus: { _, _ in
            makeStatus(changed: 7, remote: .checked)
        })
        manager.repos = [target, sibling]
        manager.clonedRepos = [target.id, sibling.id]
        let siblingVerdict = makeStatus(changed: 2, remote: .checked)
        manager.repoStatuses = [target.id: makeStatus(changed: 0, remote: .unchecked),
                                sibling.id: siblingVerdict]

        await manager.refreshStatus(for: target, in: account, refreshRemote: true)

        XCTAssertEqual(manager.repoStatuses[target.id]?.changedFiles, 7)
        XCTAssertEqual(manager.repoStatuses[target.id]?.remoteState, .checked)
        XCTAssertEqual(manager.repoStatuses[sibling.id], siblingVerdict,
                       "an action on one repo must not disturb another repo's badge")
    }

    /// A folder that is no longer a usable clone loses its badge instead of keeping
    /// one that describes a repo that isn't there — matching what the sweep does by
    /// rebuilding the map from scratch.
    func testScopedRefreshDropsTheEntryWhenTheCloneIsGone() async {
        let target = repo("tools")
        let sibling = repo("api")
        let (manager, _) = makeManager(repoStatus: { _, _ in nil })
        manager.repos = [target, sibling]
        manager.clonedRepos = [target.id, sibling.id]
        let siblingVerdict = makeStatus(changed: 1, remote: .checked)
        manager.repoStatuses = [target.id: makeStatus(changed: 3, remote: .checked),
                                sibling.id: siblingVerdict]

        await manager.refreshStatus(for: target, in: account, refreshRemote: true)

        XCTAssertNil(manager.repoStatuses[target.id])
        XCTAssertEqual(manager.repoStatuses[sibling.id], siblingVerdict)
    }

    /// A repo the app no longer believes is cloned is never probed at all — the
    /// guard has to come before the shell-out, not after.
    func testScopedRefreshSkipsRepoThatIsNotCloned() async {
        let probed = ProbedPaths()
        let target = repo("tools")
        let (manager, _) = makeManager(repoStatus: { path, _ in
            probed.record(path)
            return RepoStatus()
        })
        manager.repos = [target]
        manager.clonedRepos = []
        manager.repoStatuses = [target.id: makeStatus(changed: 4, remote: .checked)]

        await manager.refreshStatus(for: target, in: account, refreshRemote: true)

        XCTAssertTrue(probed.all().isEmpty, "an uncloned repo must not be shelled out to")
        XCTAssertNil(manager.repoStatuses[target.id])
    }

    /// An action can name an account other than the visible one (row actions take an
    /// explicit `Account` precisely so they survive a switch). That account's cache must
    /// still be updated, and the on-screen map must not gain a repo from it.
    func testScopedRefreshWritesOnlyTheCacheForANonVisibleAccount() async {
        let other = Account(alias: "other", name: "Other", email: "o@example.com", folder: "/tmp/gitnest-other")
        let target = repo("tools")
        let (manager, accounts) = makeManager(repoStatus: { _, _ in
            makeStatus(changed: 9, remote: .checked)
        })
        manager.repoCache[account.alias] = [target]
        manager.clonedReposCache[account.alias] = [target.id]
        accounts.accounts = [account, other]
        accounts.selectedAccount = other

        await manager.refreshStatus(for: target, in: account, refreshRemote: true)

        XCTAssertEqual(manager.repoStatusesCache[account.alias]?[target.id]?.changedFiles, 9)
        XCTAssertNil(manager.repoStatuses[target.id],
                     "the visible account's map must not gain another account's repo")
    }

    /// The local-only callers (commit, stash, delete) go through the same path with
    /// `refreshRemote` off, so the carry-forward has to survive the merge — otherwise a
    /// commit would blank the green "up to date" pill the last live fetch established.
    func testScopedLocalRefreshKeepsTheLastLiveVerdict() async {
        let target = repo("tools")
        let (manager, _) = makeManager(repoStatus: { _, refreshRemote in
            XCTAssertFalse(refreshRemote, "local callers must not trigger a fetch")
            var fresh = RepoStatus()
            fresh.changedFiles = 0
            fresh.hasUpstream = true
            fresh.upstreamRef = "origin/main"
            fresh.remoteState = .unchecked
            return fresh
        })
        manager.repos = [target]
        manager.clonedRepos = [target.id]
        var prior = RepoStatus()
        prior.changedFiles = 5
        prior.hasUpstream = true
        prior.upstreamRef = "origin/main"
        prior.remoteState = .checked
        manager.repoStatuses = [target.id: prior]

        await manager.refreshStatus(for: target, in: account)

        XCTAssertEqual(manager.repoStatuses[target.id]?.changedFiles, 0,
                       "the fresh local read still wins for local facts")
        XCTAssertEqual(manager.repoStatuses[target.id]?.remoteState, .checked,
                       "but the last live remote verdict is carried forward")
    }

    /// The sweep merges against the map as it is when its probes *finish*, not when
    /// the sweep began: a scoped live refresh (push/pull/fetch) can commit its
    /// verdict while the 10s tick's git processes are still running, and a sweep
    /// that carried forward from a pre-probe snapshot would revert that verdict
    /// until the next live pass — minutes of a wrongly-red (or missing-green) pill.
    func testLocalSweepKeepsLiveVerdictCommittedMidSweep() async {
        let target = repo("tools")
        let probeStarted = AtomicFlag()
        let allowProbe = DispatchSemaphore(value: 0)
        let (manager, _) = makeManager(repoStatus: { _, refreshRemote in
            XCTAssertFalse(refreshRemote, "the 10s tick sweep is local-only")
            probeStarted.set()
            allowProbe.wait()
            var fresh = RepoStatus()
            fresh.hasUpstream = true
            fresh.upstreamRef = "origin/main"
            fresh.remoteState = .unchecked
            return fresh
        })
        manager.repos = [target]
        manager.clonedRepos = [target.id]

        let sweep = Task { await manager.refreshStatuses(for: account) }
        // Spin (yielding the main actor so the sweep can reach its probe) until the
        // probe is provably in flight.
        while !probeStarted.isSet { await Task.yield() }
        // A scoped live refresh lands its verdict while the sweep's probe runs.
        var live = RepoStatus()
        live.hasUpstream = true
        live.upstreamRef = "origin/main"
        live.remoteState = .checked
        manager.repoStatuses = [target.id: live]
        manager.repoStatusesCache[account.alias] = [target.id: live]
        allowProbe.signal()
        await sweep.value

        XCTAssertEqual(manager.repoStatuses[target.id]?.remoteState, .checked,
                       "a local sweep must not revert a live verdict that landed mid-sweep")
    }

    // MARK: Carry-forward rule

    /// A local-only rescan keeps the last live verdict while the upstream ref is
    /// unchanged — otherwise every 10s tick would wipe the green "up to date" pill.
    func testLocalRescanCarriesForwardLiveVerdict() {
        var fresh = RepoStatus()
        fresh.hasUpstream = true
        fresh.upstreamRef = "origin/main"
        fresh.remoteState = .unchecked

        var prior = RepoStatus()
        prior.hasUpstream = true
        prior.upstreamRef = "origin/main"
        prior.remoteState = .checked

        XCTAssertEqual(RepoManager.carryingForwardRemoteState(fresh, previous: prior).remoteState, .checked)
    }

    /// When the branch has been re-pointed at a different upstream, the old verdict
    /// describes a comparison that no longer applies and must be dropped.
    func testLocalRescanDropsVerdictWhenUpstreamChanged() {
        var fresh = RepoStatus()
        fresh.hasUpstream = true
        fresh.upstreamRef = "origin/release"
        fresh.remoteState = .unchecked

        var prior = RepoStatus()
        prior.hasUpstream = true
        prior.upstreamRef = "origin/main"
        prior.remoteState = .checked

        XCTAssertEqual(RepoManager.carryingForwardRemoteState(fresh, previous: prior).remoteState, .unchecked)
    }

    /// A live pass never carries anything forward — its own result is authoritative,
    /// including when it downgrades a previously green repo to `[gone]`.
    func testFreshUpstreamGoneIsNotOverwrittenByPriorVerdict() {
        var fresh = RepoStatus()
        fresh.hasUpstream = true
        fresh.upstreamRef = "origin/main"
        fresh.remoteState = .upstreamGone

        var prior = RepoStatus()
        prior.hasUpstream = true
        prior.upstreamRef = "origin/main"
        prior.remoteState = .checked

        XCTAssertEqual(RepoManager.carryingForwardRemoteState(fresh, previous: prior).remoteState, .upstreamGone)
    }
}
