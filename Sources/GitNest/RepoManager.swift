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

    /// Repos narrowed by the wild-search query and optional attention filter, then
    /// sorted (cloned on top). Cached so the list avoids O(n log n) work on every
    /// view update.
    @Published var filteredRepos: [Repo] = []
    private var filteredReposCancellable: AnyCancellable?

    /// Active attention-strip filter (`nil` = show everything that matches search).
    @Published var attentionFilter: RepoAttentionKind? = nil

    /// Repo briefly highlighted after init (or similar reveal) so the row is easy
    /// to spot when the list scrolls. Cleared automatically after a short linger.
    @Published var highlightRepoID: Repo.ID?
    private var highlightClearTask: Task<Void, Never>?
    static let highlightLingerNanoseconds: UInt64 = 1_600_000_000

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
    /// When a `loadRepos` arrives while one is already running for that owner, we
    /// record the request here and run another pass after the in-flight one
    /// finishes — instead of silently dropping it. Dropping was the bug behind
    /// "init succeeded but the new repo never appeared until restart": the
    /// post-init refresh (or a manual Load repos) could land during the long
    /// remote-status pass and be ignored, leaving a stale list on screen.
    private var pendingRepoLoads: [String: PendingRepoLoad] = [:]
    private var repoLoadWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    var repoAutoRefreshAccounts: Set<String> = []
    var repoLastRefreshAt: [String: Date] = [:]

    /// Intent coalesced onto an in-flight load. `silent` stays true only if every
    /// waiter wants silent; `userInitiated` becomes true if any waiter does.
    private struct PendingRepoLoad {
        var silent: Bool
        var userInitiated: Bool

        mutating func merge(silent: Bool, userInitiated: Bool) {
            self.silent = self.silent && silent
            self.userInitiated = self.userInitiated || userInitiated
        }
    }

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
    /// Per-clone status probe. Injected so the local-first/live-remote ordering is
    /// testable without fetching a real repository.
    private let repoStatus: @Sendable (String, Bool) -> RepoStatus?
    private let localFolderState: @Sendable (Repo, String, String) -> LocalRepoFolderState
    /// A scoped action can finish while a slow account-wide scan is still reading
    /// siblings. Only the latest request for each repo may publish its result.
    private var statusRefreshSessions: [String: [Repo.ID: UUID]] = [:]
    private var cloneScanSessions: [String: UUID] = [:]
    /// Only the account being fetched must defer local ticks. A slow background
    /// account must not freeze the visible account's dirty/stash/ahead badges.
    private var liveStatusSessions: [String: Set<UUID>] = [:]

    init(
        ghChain: GhChain,
        logStore: LogStore,
        accountManager: AccountManager,
        listRepos: @escaping @Sendable (String) -> Result<[Repo], CommandError> = {
            GitHub.listRepos(owner: $0)
        },
        repoStatus: @escaping @Sendable (String, Bool) -> RepoStatus? = {
            GitHub.status(at: $0, refreshRemote: $1)
        },
        localFolderState: @escaping @Sendable (Repo, String, String) -> LocalRepoFolderState = {
            AppModel.localFolderState(for: $0, path: $1, expectedSSHHost: $2)
        }
    ) {
        self.ghChain = ghChain
        self.logStore = logStore
        self.accountManager = accountManager
        self.listRepos = listRepos
        self.repoStatus = repoStatus
        self.localFolderState = localFolderState
        bindFilteredRepos()
        rebuildFilteredRepos()
    }

    private func bindFilteredRepos() {
        filteredReposCancellable = Publishers.CombineLatest(
            Publishers.CombineLatest4($repoSearch, $repos, $repoSortField, $repoSortAscending),
            Publishers.CombineLatest3($clonedRepos, $repoStatuses, $attentionFilter)
        )
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
            sortAscending: repoSortAscending,
            attentionFilter: attentionFilter,
            statuses: repoStatuses
        )
    }

    /// Attention counts for the strip — all cloned repos with status, independent
    /// of the current search/filter so the chips stay stable while browsing.
    var attentionSummary: RepoAttentionSummary {
        RepoAttention.summary(statuses: repoStatuses, clonedRepos: clonedRepos)
    }

    nonisolated static func filteredRepos(query: String,
                                          repos: [Repo],
                                          clonedRepos: Set<Repo.ID>,
                                          sortField: RepoSortField,
                                          sortAscending: Bool,
                                          attentionFilter: RepoAttentionKind? = nil,
                                          statuses: [Repo.ID: RepoStatus] = [:]) -> [Repo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = trimmed.isEmpty ? repos : repos.filter { RepoSearch.matches(query: trimmed, repo: $0) }
        if let attentionFilter {
            base = base.filter { repo in
                guard let status = statuses[repo.id] else { return false }
                return RepoAttention.matches(status, kind: attentionFilter)
            }
        }
        return base.sorted { a, b in
            reposInOrder(a, b, clonedRepos: clonedRepos, sortField: sortField, sortAscending: sortAscending)
        }
    }

    /// Toggle an attention chip: same chip again clears; another chip replaces.
    func toggleAttentionFilter(_ kind: RepoAttentionKind) {
        attentionFilter = (attentionFilter == kind) ? nil : kind
    }

    /// Move the selection within the currently filtered list. `delta` of -1/+1
    /// is ↑/↓; with nothing selected, ↓ lands on the first row and ↑ on the last.
    func moveRepoSelection(by delta: Int) {
        let list = filteredRepos
        guard !list.isEmpty else { return }
        let currentIndex = selectedRepo.flatMap { id in list.firstIndex(where: { $0.id == id }) }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = max(0, min(list.count - 1, currentIndex + delta))
        } else {
            nextIndex = delta >= 0 ? 0 : list.count - 1
        }
        selectedRepo = list[nextIndex].id
        if let alias = accountManager.selectedAccount?.alias {
            selectedRepoCache[alias] = list[nextIndex].id
        }
    }

    /// Brief accent flash on a row so a just-revealed repo is easy to find.
    func flashHighlight(for repoID: Repo.ID) {
        highlightClearTask?.cancel()
        highlightRepoID = repoID
        highlightClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.highlightLingerNanoseconds)
            guard !Task.isCancelled, let self, self.highlightRepoID == repoID else { return }
            self.highlightRepoID = nil
            self.highlightClearTask = nil
        }
    }

    /// Cloned-first, then the selected column/direction, with name as a stable
    /// tie-break so equal dates keep a deterministic order.
    nonisolated static func reposInOrder(_ a: Repo, _ b: Repo,
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
        repoSortField = .updated
        repoSortAscending = false
        guard let raw = UserDefaults.standard.string(forKey: Self.sortDefaultsKey(for: alias)) else { return }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return }
        repoSortField = parts[0] == "name" ? .name : .updated
        repoSortAscending = parts[1] == "asc"
    }

    // MARK: Repo loading

    /// True while the visible account is mid list-fetch or mid remote-status pass.
    /// Header actions (Load repos / Init / Fork) disable on this so a click can't
    /// look like a no-op while `repoLoadsInFlight` is still held.
    var isBusyWithVisibleRepoLoad: Bool {
        isLoadingRepos || isRefreshingRepos || isCheckingRepoRemotes
    }

    func loadRepos(for account: Account, silent: Bool = false, userInitiated: Bool = true) async {
        let owner = account.alias
        if userInitiated { repoAutoRefreshAccounts.insert(owner) }

        // Coalesce onto the in-flight pass instead of returning immediately. The
        // caller still awaits until a load that includes their intent has finished
        // (including any follow-up pass drained from `pendingRepoLoads`).
        if repoLoadsInFlight.contains(owner) {
            var pending = pendingRepoLoads[owner] ?? PendingRepoLoad(silent: silent, userInitiated: userInitiated)
            pending.merge(silent: silent, userInitiated: userInitiated)
            pendingRepoLoads[owner] = pending
            await waitForRepoLoadIdle(owner)
            return
        }

        repoLoadsInFlight.insert(owner)
        defer {
            repoLoadsInFlight.remove(owner)
            resumeRepoLoadWaiters(owner)
        }

        var passSilent = silent
        var passUserInitiated = userInitiated
        while true {
            if passUserInitiated { repoAutoRefreshAccounts.insert(owner) }
            await performRepoLoad(for: account, silent: passSilent)
            if let pending = pendingRepoLoads.removeValue(forKey: owner) {
                passSilent = pending.silent
                passUserInitiated = pending.userInitiated
                continue
            }
            break
        }
    }

    private func waitForRepoLoadIdle(_ owner: String) async {
        guard repoLoadsInFlight.contains(owner) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            repoLoadWaiters[owner, default: []].append(continuation)
        }
    }

    private func resumeRepoLoadWaiters(_ owner: String) {
        let waiters = repoLoadWaiters.removeValue(forKey: owner) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func performRepoLoad(for account: Account, silent: Bool) async {
        let owner = account.alias
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
            await refreshStatusesLocallyThenRemotely(for: account)
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

    /// Insert or replace `repo` in the account's cache (and the visible list when
    /// that account is selected). Used after init so a just-created repo appears
    /// even when `user/repos` briefly lags behind `gh repo create`.
    func upsertRepo(_ repo: Repo, for account: Account) {
        let owner = account.alias
        var list = repoCache[owner] ?? []
        if accountManager.selectedAccount?.alias == owner, list.isEmpty, !repos.isEmpty {
            // Visible list is the source of truth until the first cache write.
            list = repos
        }
        if let index = list.firstIndex(where: { $0.id == repo.id }) {
            list[index] = repo
        } else {
            list.insert(repo, at: 0)
        }
        repoCache[owner] = list
        if accountManager.selectedAccount?.alias == owner {
            repos = list
        }
    }

    /// Make sure `repo` is on screen for `account`: upsert if missing, clear a
    /// search/filter that would hide it, select the row, and briefly highlight it.
    func ensureRepoVisible(_ repo: Repo, for account: Account) {
        let owner = account.alias
        let cached = repoCache[owner] ?? (accountManager.selectedAccount?.alias == owner ? repos : [])
        if !cached.contains(where: { $0.id == repo.id }) {
            upsertRepo(repo, for: account)
        }
        guard accountManager.selectedAccount?.alias == owner else { return }
        let query = repoSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty && !RepoSearch.matches(query: query, repo: repo) {
            repoSearch = ""
        }
        // Attention filters only match rows with status; a just-init'd repo often
        // has none yet, so clear any active chip that would hide it.
        if attentionFilter != nil {
            attentionFilter = nil
        }
        selectedRepo = repo.id
        selectedRepoCache[owner] = repo.id
        flashHighlight(for: repo.id)
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
    /// result. Per-owner coalescing in loadRepos serializes overlapping loads: a
    /// request that arrives mid-flight queues a follow-up pass instead of stacking
    /// concurrent gh list calls.
    func autoRefreshRepoListTick() async {
        guard repoAutoRefreshSeconds > 0, canAutoRefresh else { return }
        let selected = accountManager.selectedAccount?.alias
        let targets = accountManager.accounts
            .filter { repoAutoRefreshAccounts.contains($0.alias) }
            .filter { shouldAutoRefreshRepos(for: $0.alias) }
            .sorted { ($0.alias == selected ? 1 : 0) < ($1.alias == selected ? 1 : 0) }
        for account in targets {
            guard !Task.isCancelled, appIsActive, canAutoRefresh, repoAutoRefreshSeconds > 0 else { return }
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
            !isCheckingRepoRemotes,
            // Scoped Fetch/Push/Pull checks need the same protection as a
            // post-load sweep: a timer tick must not supersede their live result.
            liveStatusSessions[account.alias, default: []].isEmpty
        else { return }
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
        let previous = accountManager.selectedAccount?.alias == alias ? repoStatuses : (repoStatusesCache[alias] ?? [:])
        let requestedIDs = Set(sourceRepos.map(\.id)).union(previous.keys)
        let session = UUID()
        if refreshRemote { liveStatusSessions[alias, default: []].insert(session) }
        defer { liveStatusSessions[alias]?.remove(session) }
        for id in requestedIDs {
            statusRefreshSessions[alias, default: [:]][id] = session
        }
        let repoStatus = self.repoStatus
        let probed = await runBlocking { () -> [Repo.ID: RepoStatus] in
            var out: [Repo.ID: RepoStatus] = [:]
            for target in targets {
                guard let status = repoStatus(target.path, refreshRemote) else { continue }
                out[target.id] = status
            }
            return out
        }
        // Merge against state at completion, preserving newer scoped results and
        // publishing once so a large sweep does not trigger one view update per repo.
        var next = accountManager.selectedAccount?.alias == alias ? repoStatuses : (repoStatusesCache[alias] ?? [:])
        let currentClones = cloneState(for: alias).cloned
        for id in requestedIDs where statusRefreshSessions[alias]?[id] == session {
            statusRefreshSessions[alias]?.removeValue(forKey: id)
            if currentClones.contains(id), let status = probed[id] {
                next[id] = refreshRemote ? status : Self.carryingForwardRemoteState(status, previous: next[id])
            } else {
                next.removeValue(forKey: id)
            }
        }
        repoStatusesCache[alias] = next
        if accountManager.selectedAccount?.alias == alias, next != repoStatuses { repoStatuses = next }
    }

    /// Local-only rescans don't fetch, so they can't re-confirm the remote — they'd
    /// reset every row to `.unchecked` and wipe the green "current after live fetch"
    /// pill on the next 10s tick. Carry forward the last live-fetch verdict while the
    /// upstream is unchanged (and the fresh parse hasn't found something newer, e.g.
    /// `[gone]`).
    ///
    /// Pure + `nonisolated` so the account-wide sweep and the single-repo probe share
    /// one rule instead of two copies that can drift, and so the rule itself is
    /// directly unit-testable.
    nonisolated static func carryingForwardRemoteState(_ status: RepoStatus,
                                                       previous: RepoStatus?) -> RepoStatus {
        guard status.remoteState == .unchecked, let previous else { return status }
        var next = status
        if status.hasUpstream, previous.hasUpstream, previous.upstreamRef == status.upstreamRef {
            switch previous.remoteState {
            case .checked, .failed:
                next.remoteState = previous.remoteState
            case .unchecked, .noUpstream, .upstreamGone:
                break
            }
        } else if !status.hasUpstream, !previous.hasUpstream, previous.remoteState == .noUpstream {
            next.remoteState = .noUpstream
        }
        return next
    }

    /// Re-probe a single clone and merge just its entry.
    ///
    /// Every repo action uses this instead of the account-wide sweep, because an action
    /// only ever changes the one repo it ran in. With `refreshRemote` (clone/pull/fetch/
    /// push) that matters most: pushing one repo used to fetch every other clone in the
    /// account, so the row stayed disabled for N sequential network round trips over
    /// work it hadn't done. The local-only callers (commit, stash, delete) scope for the
    /// same reason, minus the network — they were spawning 2 git processes per sibling
    /// to re-read state nothing had touched.
    ///
    /// Siblings keep their last verdict via `carryingForwardRemoteState` — the same
    /// carry-forward the 10s local tick already relies on — and are picked up by that
    /// tick (local) and the repo-list load (live). The account-wide sweep still runs on
    /// repo-list loads, which is where a whole-account resync belongs.
    func refreshStatus(for repo: Repo, in account: Account, refreshRemote: Bool = false) async {
        let alias = account.alias
        let session = UUID()
        if refreshRemote { liveStatusSessions[alias, default: []].insert(session) }
        defer { liveStatusSessions[alias]?.remove(session) }
        statusRefreshSessions[alias, default: [:]][repo.id] = session
        let sourceCloned = accountManager.selectedAccount?.alias == alias
            ? clonedRepos
            : (clonedReposCache[alias] ?? [])
        // Not a clone (deleted, or the folder was taken over) — drop any stale entry
        // rather than leave a badge describing a repo that is no longer there.
        guard sourceCloned.contains(repo.id) else {
            commitProbedStatus(nil, for: repo.id, alias: alias, session: session, refreshRemote: refreshRemote)
            return
        }
        let path = localPath(repo, in: account)
        let repoStatus = self.repoStatus
        let probed = await runBlocking { repoStatus(path, refreshRemote) }
        commitProbedStatus(probed, for: repo.id, alias: alias, session: session, refreshRemote: refreshRemote)
    }

    private func commitProbedStatus(
        _ probed: RepoStatus?, for id: Repo.ID, alias: String,
        session: UUID, refreshRemote: Bool
    ) {
        guard statusRefreshSessions[alias]?[id] == session else { return }
        statusRefreshSessions[alias]?.removeValue(forKey: id)
        // A folder can be removed while a probe is in flight. Never revive a badge
        // after clone discovery has already established that the folder is gone.
        guard cloneState(for: alias).cloned.contains(id), let probed else {
            commitStatus(nil, for: id, alias: alias)
            return
        }
        let previous = (accountManager.selectedAccount?.alias == alias
            ? repoStatuses
            : (repoStatusesCache[alias] ?? [:]))[id]
        commitStatus(refreshRemote ? probed : Self.carryingForwardRemoteState(probed, previous: previous),
            for: id,
            alias: alias)
    }

    /// Merge (or remove) one repo's status in both the cache and — only while that
    /// account is still the visible one — the published map. Split out so the
    /// single-repo path keeps the sweep's two invariants: the target account's cache
    /// is always authoritative, and nothing is published for an account the user has
    /// since switched away from.
    private func commitStatus(_ status: RepoStatus?, for id: Repo.ID, alias: String) {
        var cache = repoStatusesCache[alias] ?? [:]
        if let status {
            cache[id] = status
        } else {
            cache.removeValue(forKey: id)
        }
        repoStatusesCache[alias] = cache

        guard accountManager.selectedAccount?.alias == alias else { return }
        // Same "only publish real changes" rule as the sweep — a no-op probe must not
        // re-render the list and reset hover/tooltip tracking.
        if let status {
            if repoStatuses[id] != status { repoStatuses[id] = status }
        } else if repoStatuses[id] != nil {
            repoStatuses.removeValue(forKey: id)
        }
    }

    /// Publish the cheap local view first so change/stash/ahead badges become
    /// usable without waiting for every network fetch. The live pass stays
    /// sequential for now: this improves perceived latency without increasing
    /// concurrent SSH/network load.
    func refreshStatusesLocallyThenRemotely(for account: Account) async {
        await refreshStatuses(for: account)
        await refreshStatuses(for: account, refreshRemote: true)
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
        let session = UUID()
        cloneScanSessions[alias] = session
        let sourceRepos = accountManager.selectedAccount?.alias == alias ? repos : (repoCache[alias] ?? [])
        let localFolderState = self.localFolderState
        let scan = await runBlocking { () -> (present: Set<Repo.ID>, conflicts: [Repo.ID: RepoFolderConflict]) in
            var present: Set<Repo.ID> = []
            var conflicts: [Repo.ID: RepoFolderConflict] = [:]
            for repo in sourceRepos {
                let path = (account.folder as NSString).appendingPathComponent(repo.name)
                switch localFolderState(repo, path, account.sshHost) {
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
        guard cloneScanSessions[alias] == session else { return }
        commitCloneState(scan.present, scan.conflicts, for: alias)
    }

    /// Persist a cloned/conflict update to `alias`'s cache, mirroring it into the
    /// visible sets only while that account is still the selected one.
    func commitCloneState(_ cloned: Set<Repo.ID>,
                          _ conflicts: [Repo.ID: RepoFolderConflict],
                          for alias: String) {
        cloneScanSessions.removeValue(forKey: alias)
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
        attentionFilter = nil
        highlightClearTask?.cancel()
        highlightRepoID = nil

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
