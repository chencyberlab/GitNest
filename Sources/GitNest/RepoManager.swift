import SwiftUI
import Combine

@MainActor
final class RepoManager: ObservableObject {
    @Published var repos: [Repo] = []
    @Published var repoSearch: String = ""
    @Published var selectedRepo: Repo.ID?

    /// Column the repo list sorts by, and direction. Cloned repos always group
    /// on top regardless; this only orders within the cloned and remote groups.
    @Published var repoSortField: RepoSortField = .updated
    @Published var repoSortAscending: Bool = false   // updated default: newest first

    /// Repos narrowed by the wild-search query, then sorted (cloned on top).
    /// This is a cached derivative of `repos`, `repoSearch`, `repoSortField`,
    /// `repoSortAscending`, and `clonedRepos`; it is recomputed only when one of
    /// those inputs changes, avoiding O(n log n) work on every view update.
    @Published var filteredRepos: [Repo] = []
    private var filteredReposCancellable: AnyCancellable?

    @Published var clonedRepos: Set<Repo.ID> = []
    @Published var repoStatuses: [Repo.ID: RepoStatus] = [:]
    @Published var repoFolderConflicts: [Repo.ID: RepoFolderConflict] = [:]

    @Published var isLoadingRepos = false
    @Published var isRefreshingRepos = false
    @Published var isCheckingRepoRemotes = false
    @Published var repoRefreshMessage: String?

    var repoCache: [String: [Repo]] = [:]
    var clonedReposCache: [String: Set<Repo.ID>] = [:]
    var repoStatusesCache: [String: [Repo.ID: RepoStatus]] = [:]
    var repoFolderConflictsCache: [String: [Repo.ID: RepoFolderConflict]] = [:]
    var repoSearchCache: [String: String] = [:]
    var selectedRepoCache: [String: Repo.ID] = [:]
    var repoLoadsInFlight: Set<String> = []
    var repoAutoRefreshAccounts: Set<String> = []
    var repoLastRefreshAt: [String: Date] = [:]

    /// Seconds between automatic rescans of cloned-repo status. Change here to tune.
    static let statusRefreshSeconds: UInt64 = 10
    var statusTimer: Task<Void, Never>?
    var repoAutoRefreshTimer: Task<Void, Never>?
    // Bumped each time a timer is (re)created. A timer loop clears its own var on
    // exit only when the generation still matches, so a stop+start race can never
    // leave a finished-but-non-nil Task wedging the `== nil` restart guards.
    private var statusTimerGeneration = 0
    private var repoAutoRefreshGeneration = 0
    var repoAutoRefreshSeconds: UInt64 = 5 * 60

    /// Accounts you're not currently viewing refresh no more often than this,
    /// regardless of the chosen interval — the on-switch refresh keeps them instant
    /// when you actually open them. Bounds background polling cost across accounts.
    static let backgroundRefreshFloorSeconds: UInt64 = 5 * 60

    /// How long the "Repos refreshed just now." confirmation lingers before it
    /// auto-clears, plus the task that performs that delayed clear.
    static let refreshMessageLingerSeconds: UInt64 = 10
    var repoRefreshMessageDismiss: Task<Void, Never>?

    private let ghChain: GhChain
    private let logStore: LogStore
    private let accountManager: AccountManager
    /// The repo-list fetch, injectable so tests can drive `loadRepos` down its
    /// success/failure branches without a network call. Production passes the real
    /// `GitHub.listRepos`.
    private let listRepos: @Sendable (String) -> Result<[Repo], CommandError>

    init(ghChain: GhChain,
         logStore: LogStore,
         accountManager: AccountManager,
         listRepos: @escaping @Sendable (String) -> Result<[Repo], CommandError> = {
             GitHub.listRepos(owner: $0)
         }) {
        self.ghChain = ghChain
        self.logStore = logStore
        self.accountManager = accountManager
        self.listRepos = listRepos
        bindFilteredRepos()
        rebuildFilteredRepos()
    }

    private func bindFilteredRepos() {
        filteredReposCancellable = Publishers
            .CombineLatest4($repoSearch, $repos, $repoSortField, $repoSortAscending)
            .combineLatest($clonedRepos)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.rebuildFilteredRepos()
                }
            }
    }

    /// Recompute `filteredRepos` from the current inputs. Exposed so tests can
    /// verify the cache without relying on the Combine pipeline.
    func rebuildFilteredRepos() {
        filteredRepos = Self.filteredRepos(
            query: repoSearch,
            repos: repos,
            clonedRepos: clonedRepos,
            sortField: repoSortField,
            sortAscending: repoSortAscending
        )
    }

    static func filteredRepos(query: String,
                              repos: [Repo],
                              clonedRepos: Set<Repo.ID>,
                              sortField: RepoSortField,
                              sortAscending: Bool) -> [Repo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? repos : repos.filter { RepoSearch.matches(query: trimmed, repo: $0) }
        return base.sorted { a, b in
            reposInOrder(a, b, clonedRepos: clonedRepos, sortField: sortField, sortAscending: sortAscending)
        }
    }

    /// Cloned-first, then the selected column/direction, with name as a stable
    /// tie-break so equal dates keep a deterministic order.
    static func reposInOrder(_ a: Repo, _ b: Repo,
                             clonedRepos: Set<Repo.ID>,
                             sortField: RepoSortField,
                             sortAscending: Bool) -> Bool {
        let ac = clonedRepos.contains(a.id), bc = clonedRepos.contains(b.id)
        if ac != bc { return ac }   // cloned rows pinned above remote-only rows
        switch sortField {
        case .name:
            let r = a.name.localizedCaseInsensitiveCompare(b.name)
            if r != .orderedSame { return sortAscending == (r == .orderedAscending) }
        case .updated:
            let x = a.updatedAt ?? "", y = b.updatedAt ?? ""   // ISO-8601 sorts lexically
            if x != y { return sortAscending == (x < y) }
        }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// Header click: same column flips direction; a new column resets to its
    /// natural default (names A→Z, dates newest-first).
    func sortBy(_ field: RepoSortField) {
        if repoSortField == field {
            repoSortAscending.toggle()
        } else {
            repoSortField = field
            repoSortAscending = (field == .name)
        }
        if let alias = accountManager.selectedAccount?.alias {
            saveSortState(for: alias)
        }
    }

    private static func sortDefaultsKey(for alias: String) -> String { "repoSort-\(alias)" }

    func saveSortState(for alias: String) {
        let field = repoSortField == .name ? "name" : "updated"
        let direction = repoSortAscending ? "asc" : "desc"
        UserDefaults.standard.set("\(field)|\(direction)", forKey: Self.sortDefaultsKey(for: alias))
    }

    private func loadSortState(for alias: String) {
        guard let raw = UserDefaults.standard.string(forKey: Self.sortDefaultsKey(for: alias)) else { return }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return }
        repoSortField = parts[0] == "name" ? .name : .updated
        repoSortAscending = parts[1] == "asc"
    }

    // MARK: Repo loading

    func loadRepos(for account: Account, silent: Bool = false, userInitiated: Bool = true) async {
        let owner = account.alias
        guard !repoLoadsInFlight.contains(owner) else { return }
        repoLoadsInFlight.insert(owner)
        defer { repoLoadsInFlight.remove(owner) }
        if userInitiated { repoAutoRefreshAccounts.insert(owner) }

        let isVisibleAccount = accountManager.selectedAccount?.alias == owner
        let hasVisibleRepos = isVisibleAccount && !repos.isEmpty
        if isVisibleAccount {
            isLoadingRepos = !hasVisibleRepos
            isRefreshingRepos = hasVisibleRepos
            setRepoRefreshMessage("Refreshing repos…")
            if !silent && !hasVisibleRepos {
                repoSearch = ""
                selectedRepo = nil
                repoStatuses = [:]
            }
        }

        logStore.append((silent || hasVisibleRepos) ? "Refreshing repos for \(owner)…" : "Listing repos for \(owner)…")
        let listRepos = self.listRepos
        let result = await ghChain.serializedPreservingActiveAccount { listRepos(owner) }
        if accountManager.selectedAccount?.alias == owner {
            isLoadingRepos = false
            isRefreshingRepos = false
        }

        switch result {
        case .success(let list):
            // Record the refresh time only on success. A failed refresh (network
            // blip, transient 5xx) must NOT push out the next auto-refresh tick —
            // otherwise the account would sit stale until the full interval elapses
            // instead of being retried promptly. Rate-limit backoff is handled
            // separately by `shouldAutoRefreshRepos`'s `isRateLimited` check.
            repoLastRefreshAt[owner] = Date()
            repoCache[owner] = list
            logStore.append("Found \(list.count) repo(s) for \(owner).")
            if accountManager.selectedAccount?.alias == owner {
                repos = list
                isCheckingRepoRemotes = true
                setRepoRefreshMessage(nil)
                if let selectedRepo, !list.contains(where: { $0.id == selectedRepo }) {
                    self.selectedRepo = nil
                    selectedRepoCache.removeValue(forKey: owner)
                }
            }
            await refreshClonedStatus(for: account)
            await refreshStatuses(for: account, refreshRemote: true)
            if accountManager.selectedAccount?.alias == owner {
                isCheckingRepoRemotes = false
                setRepoRefreshMessage("Repos and remote status refreshed just now.", autoDismiss: true)
            }
        case .failure(let error):
            logStore.append("✗ repo list failed: \(error.message)")
            let hasCachedRepos = repoCache[owner]?.isEmpty == false
            if hasCachedRepos {
                logStore.append("Showing cached repos for \(owner).")
            }
            if accountManager.selectedAccount?.alias == owner {
                isCheckingRepoRemotes = false
                // Don't claim "showing cached repos" when there are none — a
                // first-ever load that fails has nothing cached to fall back to.
                setRepoRefreshMessage(Self.repoRefreshFailureMessage(hasCachedRepos: hasCachedRepos))
            }
        }
    }

    /// Status-line copy for a failed repo refresh. Pure + `nonisolated` so the
    /// "don't promise cached repos that don't exist" branch is testable without
    /// driving `loadRepos` (which shells out through the gh chain).
    nonisolated static func repoRefreshFailureMessage(hasCachedRepos: Bool) -> String {
        hasCachedRepos
            ? "Repo refresh failed — showing cached repos."
            : "Repo refresh failed — couldn't reach GitHub."
    }

    // MARK: Auto-refresh

    /// Re-scan cloned-repo status on a fixed interval so the row badges pick up
    /// changes made outside the app (editor/terminal). Paused while the app is in
    /// the background; each tick waits for the previous scan to finish.
    func startStatusAutoRefresh(appIsActive: Bool) {
        guard statusTimer == nil, appIsActive else { return }
        statusTimerGeneration &+= 1
        let generation = statusTimerGeneration
        statusTimer = Task { [weak self] in
            defer {
                // Clear the var on natural exit, but only if a newer timer hasn't
                // replaced this one — otherwise we'd nil out the live timer.
                if let self, self.statusTimerGeneration == generation { self.statusTimer = nil }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.statusRefreshSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self, self.appIsActive else { return }
                await self.autoRefreshStatusesTick()
            }
        }
    }

    func stopStatusAutoRefresh() {
        statusTimer?.cancel()
        statusTimer = nil
    }

    func configureRepoAutoRefresh(seconds: Int, appIsActive: Bool) {
        if seconds > 0,
           repoAutoRefreshTimer != nil,
           repoAutoRefreshSeconds == UInt64(seconds) {
            return
        }
        if seconds <= 0,
           repoAutoRefreshTimer == nil,
           repoAutoRefreshSeconds == 0 {
            return
        }

        repoAutoRefreshTimer?.cancel()
        repoAutoRefreshTimer = nil
        guard seconds > 0, appIsActive else {
            // `max(0, …)` because UInt64(negative) traps; a non-positive interval
            // means "off" → store 0. While backgrounded we remember a positive
            // interval so resume can restart it.
            repoAutoRefreshSeconds = appIsActive ? 0 : UInt64(max(0, seconds))
            if seconds <= 0 {
                isRefreshingRepos = false
                setRepoRefreshMessage(nil)
            }
            return
        }

        repoAutoRefreshSeconds = UInt64(seconds)
        let interval = repoAutoRefreshSeconds
        repoAutoRefreshGeneration &+= 1
        let generation = repoAutoRefreshGeneration
        repoAutoRefreshTimer = Task { [weak self] in
            defer {
                // Clear the var on natural exit, but only if a newer timer hasn't
                // replaced this one — otherwise we'd nil out the live timer.
                if let self, self.repoAutoRefreshGeneration == generation { self.repoAutoRefreshTimer = nil }
            }
            while !Task.isCancelled {
                // Sleep first, using the captured interval, so `self` isn't held
                // across the wait — matches startStatusAutoRefresh's pattern.
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard !Task.isCancelled, let self, self.appIsActive else { return }
                await self.autoRefreshRepoListTick()
            }
        }
    }

    func stopRepoAutoRefresh() {
        repoAutoRefreshTimer?.cancel()
        repoAutoRefreshTimer = nil
        isRefreshingRepos = false
    }

    /// Stop every scheduled timer/dismiss task. Called once from the app delegate's
    /// `applicationWillTerminate` so background work doesn't outlive the process.
    func stopAllTimers() {
        stopStatusAutoRefresh()
        stopRepoAutoRefresh()
        repoRefreshMessageDismiss?.cancel()
        repoRefreshMessageDismiss = nil
    }

    /// Single entry point for the repo-refresh status line. With `autoDismiss` the
    /// message clears itself after `refreshMessageLingerSeconds` (used for the
    /// success confirmation so it doesn't linger). Any pending dismissal is
    /// cancelled first, and the delayed clear only fires if the message is still
    /// the one it was scheduled for — so a newer message is never wiped early.
    func setRepoRefreshMessage(_ message: String?, autoDismiss: Bool = false) {
        repoRefreshMessageDismiss?.cancel()
        repoRefreshMessageDismiss = nil
        repoRefreshMessage = message
        guard autoDismiss, let message else { return }
        repoRefreshMessageDismiss = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.refreshMessageLingerSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.repoRefreshMessage == message else { return }
            self.repoRefreshMessage = nil
            self.repoRefreshMessageDismiss = nil
        }
    }

    /// When false, auto-refresh ticks are skipped. AppModel sets this while a
    /// project init/fork or add-account flow is in progress.
    var canAutoRefresh = true

    /// One interval tick: refresh every account you've loaded at least once whose
    /// effective interval has elapsed — not just the visible one — so each stays
    /// current in the background and is already fresh when you switch to it.
    /// Non-visible accounts update only their cache (no UI churn); the visible one
    /// shows the usual indicator. Accounts are refreshed one at a time through the
    /// gh chain, with the selected account last so the visible rows get the freshest
    /// result. Per-owner in-flight guards in loadRepos keep this from stacking on a
    /// manual load already running.
    func autoRefreshRepoListTick() async {
        guard repoAutoRefreshSeconds > 0, canAutoRefresh else { return }
        let selected = accountManager.selectedAccount?.alias
        let targets = accountManager.accounts
            .filter { repoAutoRefreshAccounts.contains($0.alias) }
            .filter { shouldAutoRefreshRepos(for: $0.alias) }
            .sorted { ($0.alias == selected ? 1 : 0) < ($1.alias == selected ? 1 : 0) }
        for account in targets {
            await loadRepos(for: account, silent: true, userInitiated: false)
        }
    }

    /// Whether `alias` is due for an auto-refresh, based on its *effective*
    /// interval. Used by both the timer tick and the on-switch refresh.
    func shouldAutoRefreshRepos(for alias: String) -> Bool {
        guard !GitHub.isRateLimited(owner: alias) else { return false }
        let interval = effectiveRefreshInterval(for: alias)
        guard interval > 0 else { return false }
        guard let last = repoLastRefreshAt[alias] else { return true }
        return Date().timeIntervalSince(last) >= TimeInterval(interval)
    }

    /// Per-account refresh interval in seconds (0 when auto-refresh is off). Starts
    /// from the chosen interval, then:
    ///  • accounts you're not viewing are floored to backgroundRefreshFloorSeconds
    ///    (they're refreshed on switch anyway), and
    ///  • large repo lists are stretched ~1× per 500 repos, so the request rate per
    ///    account stays roughly flat no matter how big the list grows.
    /// Net effect: small visible accounts honor your exact interval; many accounts
    /// and/or huge lists back off automatically to stay light on the GitHub API.
    func effectiveRefreshInterval(for alias: String) -> UInt64 {
        guard repoAutoRefreshSeconds > 0 else { return 0 }
        let isVisible = alias == accountManager.selectedAccount?.alias
        let base = isVisible
            ? repoAutoRefreshSeconds
            : max(repoAutoRefreshSeconds, Self.backgroundRefreshFloorSeconds)
        let count = repoCache[alias]?.count ?? 0
        let sizeMultiplier = UInt64(max(1, (count + 499) / 500))   // ceil(count / 500)
        return base * sizeMultiplier
    }

    /// One interval tick — skip while a load/init is in flight or nothing is loaded.
    func autoRefreshStatusesTick() async {
        guard let account = accountManager.selectedAccount,
              !isLoadingRepos,
              canAutoRefresh,
              !repos.isEmpty,
              // A post-load remote refresh is in flight; let it finish so this
              // local-only tick can't race it and clobber the just-fetched state.
              !isCheckingRepoRemotes else { return }
        await refreshStatuses(for: account)
    }

    /// Probe every cloned repo so rows can show pending work. The regular timer
    /// uses local status only; repo-list loads pass `refreshRemote` to fetch each
    /// upstream once and compare against current GitHub state.
    func refreshStatuses(for account: Account, refreshRemote: Bool = false) async {
        let alias = account.alias
        let sourceRepos = accountManager.selectedAccount?.alias == alias ? repos : (repoCache[alias] ?? [])
        let sourceCloned = accountManager.selectedAccount?.alias == alias ? clonedRepos : (clonedReposCache[alias] ?? [])
        let targets = sourceRepos
            .filter { sourceCloned.contains($0.id) }
            .map { (id: $0.id, path: localPath($0, in: account)) }
        guard !targets.isEmpty else {
            repoStatusesCache[alias] = [:]
            if accountManager.selectedAccount?.alias == alias, !repoStatuses.isEmpty { repoStatuses = [:] }
            return
        }
        let previous = accountManager.selectedAccount?.alias == alias ? repoStatuses : (repoStatusesCache[alias] ?? [:])
        let next = await runBlocking { () -> [Repo.ID: RepoStatus] in
            var out: [Repo.ID: RepoStatus] = [:]
            for target in targets {
                guard var status = GitHub.status(at: target.path, refreshRemote: refreshRemote) else { continue }
                // Local-only rescans don't fetch, so they can't re-confirm the
                // remote — they'd reset every row to `.unchecked` and wipe the
                // green "current after live fetch" pill on the next 10s tick.
                // Carry forward the last live-fetch verdict while the upstream is
                // unchanged (and the fresh parse hasn't found something newer,
                // e.g. `[gone]`).
                if !refreshRemote, status.remoteState == .unchecked,
                   let prev = previous[target.id] {
                    if status.hasUpstream, prev.hasUpstream, prev.upstreamRef == status.upstreamRef {
                        switch prev.remoteState {
                        case .checked, .failed:
                            status.remoteState = prev.remoteState
                        case .unchecked, .noUpstream, .upstreamGone:
                            break
                        }
                    } else if !status.hasUpstream, !prev.hasUpstream, prev.remoteState == .noUpstream {
                        status.remoteState = .noUpstream
                    }
                }
                out[target.id] = status
            }
            return out
        }
        // Only publish when something actually changed — otherwise the 10s timer
        // would re-render the repo list (and reset hover/tooltip tracking) for nothing.
        repoStatusesCache[alias] = next
        if accountManager.selectedAccount?.alias == alias, next != repoStatuses { repoStatuses = next }
    }

    // MARK: Per-repo state

    func localPath(_ repo: Repo, in account: Account) -> String {
        (account.folder as NSString).appendingPathComponent(repo.name)
    }

    func isCloned(_ repo: Repo) -> Bool { clonedRepos.contains(repo.id) }

    func folderConflict(_ repo: Repo) -> RepoFolderConflict? {
        repoFolderConflicts[repo.id]
    }

    func cloneState(for alias: String) -> (cloned: Set<Repo.ID>, conflicts: [Repo.ID: RepoFolderConflict]) {
        if accountManager.selectedAccount?.alias == alias {
            return (clonedRepos, repoFolderConflicts)
        }
        return (clonedReposCache[alias] ?? [], repoFolderConflictsCache[alias] ?? [:])
    }

    func refreshClonedStatus(for account: Account) async {
        let alias = account.alias
        let sourceRepos = accountManager.selectedAccount?.alias == alias ? repos : (repoCache[alias] ?? [])
        let scan = await runBlocking { () -> (present: Set<Repo.ID>, conflicts: [Repo.ID: RepoFolderConflict]) in
            var present: Set<Repo.ID> = []
            var conflicts: [Repo.ID: RepoFolderConflict] = [:]
            for repo in sourceRepos {
                let path = (account.folder as NSString).appendingPathComponent(repo.name)
                switch AppModel.localFolderState(for: repo,
                                                 path: path,
                                                 expectedSSHHost: account.sshHost) {
                case .cloned:
                    present.insert(repo.id)
                case .occupied(let conflict):
                    conflicts[repo.id] = conflict
                case .absent:
                    break
                }
            }
            return (present, conflicts)
        }
        clonedReposCache[alias] = scan.present
        repoFolderConflictsCache[alias] = scan.conflicts
        if accountManager.selectedAccount?.alias == alias {
            clonedRepos = scan.present
            repoFolderConflicts = scan.conflicts
        }
    }

    /// Persist a cloned/conflict update to `alias`'s cache, mirroring it into the
    /// visible sets only while that account is still the selected one.
    func commitCloneState(_ cloned: Set<Repo.ID>,
                          _ conflicts: [Repo.ID: RepoFolderConflict],
                          for alias: String) {
        clonedReposCache[alias] = cloned
        repoFolderConflictsCache[alias] = conflicts
        if accountManager.selectedAccount?.alias == alias {
            clonedRepos = cloned
            repoFolderConflicts = conflicts
        }
    }

    // MARK: Account switch cache

    /// Persist the currently visible repo state to the selected account's cache.
    func saveVisibleRepoState() {
        guard let alias = accountManager.selectedAccount?.alias else { return }
        repoCache[alias] = repos
        clonedReposCache[alias] = clonedRepos
        repoStatusesCache[alias] = repoStatuses
        repoFolderConflictsCache[alias] = repoFolderConflicts
        repoSearchCache[alias] = repoSearch
        if let selectedRepo {
            selectedRepoCache[alias] = selectedRepo
        } else {
            selectedRepoCache.removeValue(forKey: alias)
        }
    }

    /// Restore the visible repo state from the given account's cache.
    func restoreRepoState(for account: Account) {
        let alias = account.alias
        loadSortState(for: alias)
        repos = repoCache[alias] ?? []
        clonedRepos = clonedReposCache[alias] ?? []
        repoStatuses = repoStatusesCache[alias] ?? [:]
        repoFolderConflicts = repoFolderConflictsCache[alias] ?? [:]
        repoSearch = repoSearchCache[alias] ?? ""

        if let cachedSelection = selectedRepoCache[alias],
           repos.contains(where: { $0.id == cachedSelection }) {
            selectedRepo = cachedSelection
        } else {
            selectedRepo = nil
        }

        isLoadingRepos = repos.isEmpty && repoLoadsInFlight.contains(alias)
        isRefreshingRepos = !repos.isEmpty && repoLoadsInFlight.contains(alias)
        isCheckingRepoRemotes = false
        setRepoRefreshMessage(nil)
    }

    /// Whether the app is currently the active application. RepoManager does not
    /// observe activation itself; AppModel feeds this in from its workspace observers.
    var appIsActive = true
}
