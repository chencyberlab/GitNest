import SwiftUI
import AppKit

/// Sortable columns in the repo list.
enum RepoSortField: Sendable { case name, updated }

/// Steps of the add-account wizard.
enum AddAccountStep: Sendable { case signIn, folder, sshKey, finish }

/// How aggressively the app checks per-account SSH + gh readiness.
enum AccountStatusLoadMode: String, CaseIterable, Identifiable, Sendable {
    case smart
    case all
    case onDemand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: return "Smart"
        case .all: return "All on startup"
        case .onDemand: return "On demand"
        }
    }

    var help: String {
        switch self {
        case .smart:
            return "After you select an account, checks it first, then checks the other account cards in the background."
        case .all:
            return "Checks every account card as soon as the app opens."
        case .onDemand:
            return "Checks an account when you select it. Refresh rechecks the selected account."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct GhAuthIndicator: Sendable {
        let ok: Bool
        let text: String
    }

    struct PullWarning: Identifiable, Sendable {
        let id = UUID()
        let repoName: String
        let message: String

        /// Builds the user-facing alert body from Git's combined stdout+stderr.
        /// Long output is capped so the alert stays readable — the full text is
        /// always available in the Output pane.
        static func message(repoName: String, gitOutput: String) -> String {
            let output = gitOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if output.isEmpty {
                detail = "Git did not provide details."
            } else if output.count > 1200 {
                detail = String(output.prefix(1200)) + "\n\nFull output is in the Output pane."
            } else {
                detail = output
            }
            return """
            Git could not pull \(repoName). Your local files were not force-replaced.

            This usually means uncommitted changes, a divergent branch, or merge conflicts that need manual resolution — see Git's output below for the exact reason.

            \(detail)
            """
        }
    }

    private struct AddAccountLoginResult: Sendable {
        let login: ShellResult
        let identity: Result<AccountSetup.Identity, GitHubError>?
    }

    @Published var accounts: [Account] = []
    @Published var selectedAccount: Account?
    @Published var repos: [Repo] = []
    @Published var repoSearch: String = ""
    @Published var selectedRepo: Repo.ID?

    /// Column the repo list sorts by, and direction. Cloned repos always group
    /// on top regardless; this only orders within the cloned and remote groups.
    @Published var repoSortField: RepoSortField = .updated
    @Published var repoSortAscending: Bool = false   // updated default: newest first

    /// Repos narrowed by the wild-search query, then sorted (cloned on top).
    var filteredRepos: [Repo] {
        let query = repoSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = query.isEmpty ? repos : repos.filter { RepoSearch.matches(query: query, repo: $0) }
        return base.sorted(by: reposInOrder)
    }

    /// Cloned-first, then the selected column/direction, with name as a stable
    /// tie-break so equal dates keep a deterministic order.
    private func reposInOrder(_ a: Repo, _ b: Repo) -> Bool {
        let ac = isCloned(a), bc = isCloned(b)
        if ac != bc { return ac }   // cloned rows pinned above remote-only rows
        switch repoSortField {
        case .name:
            let r = a.name.localizedCaseInsensitiveCompare(b.name)
            if r != .orderedSame { return repoSortAscending == (r == .orderedAscending) }
        case .updated:
            let x = a.updatedAt ?? "", y = b.updatedAt ?? ""   // ISO-8601 sorts lexically
            if x != y { return repoSortAscending == (x < y) }
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
    }
    @Published var sshGreetings: [String: String] = [:]   // alias -> "Hi X!"
    @Published var ghIndicators: [String: GhAuthIndicator] = [:] // alias -> gh auth status
    @Published private var accountStatusChecksPending: Set<String> = []
    @Published var isLoadingRepos = false
    @Published var isRefreshingRepos = false
    @Published var isCheckingRepoRemotes = false
    @Published var repoRefreshMessage: String?
    @Published var isInitializingProject = false
    @Published var log: String = ""
    /// Whether the most recently appended log line was a failure/warning. The
    /// collapsed Output status line uses this to stay pinned on problems while
    /// progress/success lines fade away on their own.
    @Published private(set) var lastLogWasError = false
    @Published var pullWarning: PullWarning?

    // Add-account wizard state (driven by AddAccountSheet).
    @Published var addAccountActive = false
    @Published var addAccountStep: AddAccountStep = .signIn
    @Published var addAccountBusy = false
    @Published var addAccountError: String?
    @Published var addAccountDeviceCode: String?
    @Published var addAccountIdentity: AccountSetup.Identity?
    @Published var addAccountEmail: String = ""
    @Published var addAccountFolder: String?
    @Published var addAccountPublicKey: String?
    @Published var addAccountKeyCreated = false
    @Published var addAccountVerification: AccountSetup.Verification?
    @Published var clonedRepos: Set<String> = []   // repo names present on disk for the selected account
    @Published var repoStatuses: [String: RepoStatus] = [:]   // repo name -> local/upstream state
    private var currentAuthFlowCode: String?
    private var repoCache: [String: [Repo]] = [:]
    private var clonedReposCache: [String: Set<String>] = [:]
    private var repoStatusesCache: [String: [String: RepoStatus]] = [:]
    private var repoSearchCache: [String: String] = [:]
    private var selectedRepoCache: [String: Repo.ID] = [:]
    private var repoLoadsInFlight: Set<String> = []
    private var repoAutoRefreshAccounts: Set<String> = []
    private var repoLastRefreshAt: [String: Date] = [:]
    private var addAccountSessionID = UUID()
    private var accountStatusSessionID = UUID()
    private var accountStatusLoadMode: AccountStatusLoadMode = .smart
    private static let accountOrderDefaultsKey = "accountOrder"

    /// Seconds between automatic rescans of cloned-repo status. Change here to tune.
    private static let statusRefreshSeconds: UInt64 = 10
    private var statusTimer: Task<Void, Never>?
    private var repoAutoRefreshTimer: Task<Void, Never>?
    private var repoAutoRefreshSeconds: UInt64 = 5 * 60

    /// Accounts you're not currently viewing refresh no more often than this,
    /// regardless of the chosen interval — the on-switch refresh keeps them instant
    /// when you actually open them. Bounds background polling cost across accounts.
    private static let backgroundRefreshFloorSeconds: UInt64 = 5 * 60

    /// How long the "Repos refreshed just now." confirmation lingers before it
    /// auto-clears, plus the task that performs that delayed clear.
    private static let refreshMessageLingerSeconds: UInt64 = 10
    private var repoRefreshMessageDismiss: Task<Void, Never>?

    /// Tail of the serialized gh-account work chain. `gh`'s active account is
    /// global on-disk state, so the indicator sweep, repo listing, and project
    /// init must not interleave their switch+use steps — one would flip the
    /// active account out from under another. Routing them through this chain
    /// makes those sections run one at a time, in call order.
    private var ghChain: Task<Void, Never> = Task {}

    private func ghSerialized<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let previous = ghChain
        let task = Task<T, Never> {
            _ = await previous.value
            return await Task.detached(priority: .userInitiated) { work() }.value
        }
        ghChain = Task { _ = await task.value }
        return await task.value
    }

    func configureAccountStatusLoadMode(_ mode: AccountStatusLoadMode) {
        accountStatusLoadMode = mode
    }

    func refreshAll(statusMode: AccountStatusLoadMode? = nil, manual: Bool = false) {
        if let statusMode { accountStatusLoadMode = statusMode }
        accountStatusSessionID = UUID()
        accountStatusChecksPending.removeAll()
        accounts = orderedAccounts(GitConfig.loadAccounts())
        if let selectedAccount {
            self.selectedAccount = accounts.first { $0.alias == selectedAccount.alias }
        }
        startAccountStatusChecks(mode: accountStatusLoadMode, manual: manual, force: true)
    }

    /// Account switch UX: show cached repos immediately if they exist.
    /// Repo listing itself remains user-driven via the Load repos button.
    func selectAccount(_ account: Account) {
        saveVisibleRepoState()
        selectedAccount = account
        restoreRepoState(for: account)
        if repoAutoRefreshAccounts.contains(account.alias),
           shouldAutoRefreshRepos(for: account.alias) {
            Task { await loadRepos(for: account, silent: true, userInitiated: false) }
        }
        refreshAccountStatusIfNeeded(for: account)
    }

    /// Move `alias` to an absolute index in the full account list (clamped to the
    /// valid range). Used by drag-to-reorder, which computes a precise drop slot.
    /// No-ops when the order wouldn't change.
    func moveAccount(alias: String, toIndex index: Int) {
        guard let from = accounts.firstIndex(where: { $0.alias == alias }) else { return }
        var next = accounts
        let account = next.remove(at: from)
        let destination = max(0, min(index, next.count))
        next.insert(account, at: destination)
        guard next.map(\.alias) != accounts.map(\.alias) else { return }
        accounts = next
        saveAccountOrder()
    }

    private func orderedAccounts(_ loaded: [Account]) -> [Account] {
        let savedOrder = UserDefaults.standard.stringArray(forKey: Self.accountOrderDefaultsKey) ?? []
        let orderIndex = Dictionary(uniqueKeysWithValues: savedOrder.enumerated().map { ($0.element, $0.offset) })
        return loaded.enumerated()
            .sorted { lhs, rhs in
                let left = orderIndex[lhs.element.alias] ?? Int.max
                let right = orderIndex[rhs.element.alias] ?? Int.max
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func saveAccountOrder() {
        UserDefaults.standard.set(accounts.map(\.alias), forKey: Self.accountOrderDefaultsKey)
    }

    private func saveVisibleRepoState() {
        guard let alias = selectedAccount?.alias else { return }
        repoCache[alias] = repos
        clonedReposCache[alias] = clonedRepos
        repoStatusesCache[alias] = repoStatuses
        repoSearchCache[alias] = repoSearch
        if let selectedRepo {
            selectedRepoCache[alias] = selectedRepo
        } else {
            selectedRepoCache.removeValue(forKey: alias)
        }
    }

    private func restoreRepoState(for account: Account) {
        let alias = account.alias
        repos = repoCache[alias] ?? []
        clonedRepos = clonedReposCache[alias] ?? []
        repoStatuses = repoStatusesCache[alias] ?? [:]
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

    /// On-demand: run `gh auth status` and append its full output to the Output
    /// log. Triggered by the button in the Output panel header — the per-account
    /// cards already show ready/login-required, so this is just for the raw detail.
    func logAuthStatus() async {
        appendLog("$ gh auth status")
        let res = await run { GitHub.authStatus() }
        let text = (res.stdout + res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        appendLog(text.isEmpty ? "gh: no output" : text)
    }

    private func startAccountStatusChecks(mode: AccountStatusLoadMode, manual: Bool, force: Bool) {
        switch mode {
        case .smart:
            beginAccountStatusChecksSequentially(selectedFirstAccounts(), force: force)
        case .all:
            beginAccountStatusChecks(accounts, force: force)
        case .onDemand:
            if manual, let selectedAccount {
                beginAccountStatusChecks([selectedAccount], force: force)
            }
        }
    }

    private func selectedFirstAccounts() -> [Account] {
        guard let selectedAccount else { return [] }
        return [selectedAccount] + accounts.filter { $0.alias != selectedAccount.alias }
    }

    private func refreshAccountStatusIfNeeded(for account: Account) {
        switch accountStatusLoadMode {
        case .smart:
            beginAccountStatusChecksSequentially(selectedFirstAccounts(), force: false)
        case .all:
            if !accountStatusKnown(account) {
                beginAccountStatusChecks([account], force: false)
            }
        case .onDemand:
            beginAccountStatusChecks([account], force: false)
        }
    }

    private func beginAccountStatusChecks(_ requested: [Account], force: Bool) {
        var seen: Set<String> = []
        let targets = requested.filter { account in
            seen.insert(account.alias).inserted
                && !accountStatusChecksPending.contains(account.alias)
                && (force || !accountStatusKnown(account))
        }
        guard !targets.isEmpty else { return }

        let session = accountStatusSessionID
        if force {
            for account in targets {
                sshGreetings.removeValue(forKey: account.alias)
                ghIndicators.removeValue(forKey: account.alias)
            }
        }
        accountStatusChecksPending.formUnion(targets.map(\.alias))
        Task { [weak self] in
            for account in targets {
                guard let self else { return }
                await self.loadAccountStatus(account, session: session)
            }
        }
    }

    private func beginAccountStatusChecksSequentially(_ requested: [Account], force: Bool) {
        let session = accountStatusSessionID
        Task { [weak self] in
            var seen: Set<String> = []
            for account in requested where seen.insert(account.alias).inserted {
                guard let self else { return }
                await self.runAccountStatusCheckIfNeeded(account, session: session, force: force)
            }
        }
    }

    private func loadAccountStatus(_ account: Account, session: UUID) async {
        let alias = account.alias
        let greeting = await run { GitHub.sshGreeting(host: account.sshHost) }
        guard isCurrentAccountStatusSession(session, alias: alias) else { return }
        sshGreetings[alias] = greeting

        let fallback = selectedAccount?.alias ?? accounts.first?.alias
        let indicator = await ghSerialized { () -> GhAuthIndicator in
            let original = Shell.run(["gh", "api", "user", "--jq", ".login"])
            let originalLogin = original.ok
                ? original.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil

            let check = GitHub.ensureActiveAccount(alias)

            let restore = (originalLogin?.isEmpty == false) ? originalLogin : fallback
            if let restore { _ = Shell.run(["gh", "auth", "switch", "-u", restore]) }

            return GhAuthIndicator(ok: check.ok,
                                   text: check.ok ? "gh ready" : "gh login required")
        }
        guard isCurrentAccountStatusSession(session, alias: alias) else { return }
        ghIndicators[alias] = indicator
        accountStatusChecksPending.remove(alias)
    }

    private func isCurrentAccountStatusSession(_ session: UUID, alias: String) -> Bool {
        session == accountStatusSessionID
            && accounts.contains(where: { $0.alias == alias })
    }

    private func runAccountStatusCheckIfNeeded(_ account: Account, session: UUID, force: Bool) async {
        guard isCurrentAccountStatusSession(session, alias: account.alias),
              !accountStatusChecksPending.contains(account.alias),
              force || !accountStatusKnown(account)
        else { return }

        if force {
            sshGreetings.removeValue(forKey: account.alias)
            ghIndicators.removeValue(forKey: account.alias)
        }
        accountStatusChecksPending.insert(account.alias)
        await loadAccountStatus(account, session: session)
    }

    func loadRepos(for account: Account, silent: Bool = false, userInitiated: Bool = true) async {
        let owner = account.alias
        guard !repoLoadsInFlight.contains(owner) else { return }
        repoLoadsInFlight.insert(owner)
        if userInitiated { repoAutoRefreshAccounts.insert(owner) }

        let isVisibleAccount = selectedAccount?.alias == owner
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

        appendLog((silent || hasVisibleRepos) ? "Refreshing repos for \(owner)…" : "Listing repos for \(owner)…")
        let result = await ghSerialized { GitHub.listRepos(owner: owner) }
        repoLastRefreshAt[owner] = Date()
        if selectedAccount?.alias == owner {
            isLoadingRepos = false
            isRefreshingRepos = false
        }

        switch result {
        case .success(let list):
            repoCache[owner] = list
            appendLog("Found \(list.count) repo(s) for \(owner).")
            if selectedAccount?.alias == owner {
                repos = list
                isCheckingRepoRemotes = true
                setRepoRefreshMessage(nil)
                if let selectedRepo, !list.contains(where: { $0.id == selectedRepo }) {
                    self.selectedRepo = nil
                    selectedRepoCache.removeValue(forKey: owner)
                }
            }
            refreshClonedStatus(for: account)
            await refreshStatuses(for: account, refreshRemote: true)
            repoLoadsInFlight.remove(owner)
            if selectedAccount?.alias == owner {
                isCheckingRepoRemotes = false
                setRepoRefreshMessage("Repos and remote status refreshed just now.", autoDismiss: true)
            }
        case .failure(let error):
            repoLoadsInFlight.remove(owner)
            appendLog("✗ repo list failed: \(error.message)")
            if repoCache[owner]?.isEmpty == false {
                appendLog("Showing cached repos for \(owner).")
            }
            if selectedAccount?.alias == owner {
                isCheckingRepoRemotes = false
                setRepoRefreshMessage("Repo refresh failed — showing cached repos.")
            }
        }
    }

    /// Re-scan cloned-repo status on a fixed interval so the row badges pick up
    /// changes made outside the app (editor/terminal). Runs continuously,
    /// regardless of window focus; each tick waits for the previous scan to finish.
    func startStatusAutoRefresh() {
        statusTimer?.cancel()
        statusTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.statusRefreshSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.autoRefreshStatusesTick()
            }
        }
    }

    func stopStatusAutoRefresh() {
        statusTimer?.cancel()
        statusTimer = nil
    }

    func configureRepoAutoRefresh(seconds: Int) {
        repoAutoRefreshTimer?.cancel()
        repoAutoRefreshTimer = nil
        guard seconds > 0 else {
            repoAutoRefreshSeconds = 0
            isRefreshingRepos = false
            setRepoRefreshMessage(nil)
            return
        }

        repoAutoRefreshSeconds = UInt64(seconds)
        let interval = repoAutoRefreshSeconds
        repoAutoRefreshTimer = Task { [weak self] in
            while !Task.isCancelled {
                // Sleep first, using the captured interval, so `self` isn't held
                // across the wait — matches startStatusAutoRefresh's pattern.
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.autoRefreshRepoListTick()
            }
        }
    }

    func stopRepoAutoRefresh() {
        repoAutoRefreshTimer?.cancel()
        repoAutoRefreshTimer = nil
        isRefreshingRepos = false
    }

    /// Single entry point for the repo-refresh status line. With `autoDismiss` the
    /// message clears itself after `refreshMessageLingerSeconds` (used for the
    /// success confirmation so it doesn't linger). Any pending dismissal is
    /// cancelled first, and the delayed clear only fires if the message is still
    /// the one it was scheduled for — so a newer message is never wiped early.
    private func setRepoRefreshMessage(_ message: String?, autoDismiss: Bool = false) {
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

    /// One interval tick: refresh every account you've loaded at least once whose
    /// effective interval has elapsed — not just the visible one — so each stays
    /// current in the background and is already fresh when you switch to it.
    /// Non-visible accounts update only their cache (no UI churn); the visible one
    /// shows the usual indicator. Accounts are refreshed one at a time through the
    /// gh chain, with the selected account last so gh rests on the account you're
    /// viewing. Per-owner in-flight guards in loadRepos keep this from stacking on
    /// a manual load already running.
    private func autoRefreshRepoListTick() async {
        guard repoAutoRefreshSeconds > 0, !isInitializingProject, !addAccountActive else { return }
        let selected = selectedAccount?.alias
        let targets = accounts
            .filter { repoAutoRefreshAccounts.contains($0.alias) }
            .filter { shouldAutoRefreshRepos(for: $0.alias) }
            .sorted { ($0.alias == selected ? 1 : 0) < ($1.alias == selected ? 1 : 0) }
        for account in targets {
            await loadRepos(for: account, silent: true, userInitiated: false)
        }
    }

    /// Whether `alias` is due for an auto-refresh, based on its *effective*
    /// interval. Used by both the timer tick and the on-switch refresh.
    private func shouldAutoRefreshRepos(for alias: String) -> Bool {
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
    private func effectiveRefreshInterval(for alias: String) -> UInt64 {
        guard repoAutoRefreshSeconds > 0 else { return 0 }
        let isVisible = alias == selectedAccount?.alias
        let base = isVisible
            ? repoAutoRefreshSeconds
            : max(repoAutoRefreshSeconds, Self.backgroundRefreshFloorSeconds)
        let count = repoCache[alias]?.count ?? 0
        let sizeMultiplier = UInt64(max(1, (count + 499) / 500))   // ceil(count / 500)
        return base * sizeMultiplier
    }

    /// One interval tick — skip while a load/init is in flight or nothing is loaded.
    private func autoRefreshStatusesTick() async {
        guard let account = selectedAccount,
              !isLoadingRepos, !isInitializingProject, !repos.isEmpty else { return }
        await refreshStatuses(for: account)
    }

    /// Probe every cloned repo so rows can show pending work. The regular timer
    /// uses local status only; repo-list loads pass `refreshRemote` to fetch each
    /// upstream once and compare against current GitHub state.
    func refreshStatuses(for account: Account, refreshRemote: Bool = false) async {
        let alias = account.alias
        let sourceRepos = selectedAccount?.alias == alias ? repos : (repoCache[alias] ?? [])
        let sourceCloned = selectedAccount?.alias == alias ? clonedRepos : (clonedReposCache[alias] ?? [])
        let targets = sourceRepos
            .filter { sourceCloned.contains($0.name) }
            .map { (name: $0.name, path: localPath($0, in: account)) }
        guard !targets.isEmpty else {
            repoStatusesCache[alias] = [:]
            if selectedAccount?.alias == alias, !repoStatuses.isEmpty { repoStatuses = [:] }
            return
        }
        let next = await run { () -> [String: RepoStatus] in
            var out: [String: RepoStatus] = [:]
            for target in targets {
                if let status = GitHub.status(at: target.path, refreshRemote: refreshRemote) {
                    out[target.name] = status
                }
            }
            return out
        }
        // Only publish when something actually changed — otherwise the 10s timer
        // would re-render the repo list (and reset hover/tooltip tracking) for nothing.
        repoStatusesCache[alias] = next
        if selectedAccount?.alias == alias, next != repoStatuses { repoStatuses = next }
    }

    // MARK: Per-repo state

    func localPath(_ repo: Repo, in account: Account) -> String {
        (account.folder as NSString).appendingPathComponent(repo.name)
    }

    func isCloned(_ repo: Repo) -> Bool { clonedRepos.contains(repo.name) }

    /// Both per-account connection checks (SSH key greeting + gh auth) have passed.
    /// Used to gate the repo/init actions until the account is confirmed reachable.
    func accountReady(_ account: Account) -> Bool {
        accountSSHReady(account) && accountGhReady(account)
    }

    /// True while either connection check for `account` is still in flight (no
    /// result back yet) — distinguishes "still checking" from "checked and failed".
    func accountChecking(_ account: Account) -> Bool {
        accountStatusChecksPending.contains(account.alias)
    }

    func accountStatusKnown(_ account: Account) -> Bool {
        sshGreetings[account.alias] != nil && ghIndicators[account.alias] != nil
    }

    func accountSSHReady(_ account: Account) -> Bool {
        guard let greeting = sshGreetings[account.alias],
              let login = AccountSetup.sshLogin(from: greeting) else { return false }
        return AccountSetup.loginMatches(login, expectedAlias: account.alias)
    }

    func accountGhReady(_ account: Account) -> Bool {
        ghIndicators[account.alias]?.ok == true
    }

    func refreshClonedStatus(for account: Account) {
        let fm = FileManager.default
        var present: Set<String> = []
        let alias = account.alias
        let sourceRepos = selectedAccount?.alias == alias ? repos : (repoCache[alias] ?? [])
        for repo in sourceRepos {
            let git = (localPath(repo, in: account) as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: git) { present.insert(repo.name) }
        }
        clonedReposCache[alias] = present
        if selectedAccount?.alias == alias { clonedRepos = present }
    }

    func makeInitPlan(sourceURL: URL, account: Account) -> ProjectInitPlan {
        let sourcePath = sourceURL.standardizedFileURL.path
        let accountFolder = URL(fileURLWithPath: account.folder).standardizedFileURL.path
        let repoName = sanitizedRepoName(from: (sourcePath as NSString).lastPathComponent)
        let inAccountFolder = sourcePath == accountFolder || sourcePath.hasPrefix(accountFolder + "/")
        let workingPath = inAccountFolder
            ? sourcePath
            : (accountFolder as NSString).appendingPathComponent(repoName)

        return ProjectInitPlan(
            account: account,
            sourcePath: sourcePath,
            workingPath: workingPath,
            repoName: repoName,
            willCopy: !inAccountFolder
        )
    }

    // MARK: Per-repo actions

    func clone(_ repo: Repo) async {
        guard let account = selectedAccount else { return }
        appendLog("Cloning \(repo.nameWithOwner) → \(account.folder)…")
        let folder = account.folder
        let res = await run { GitHub.clone(repo: repo, into: folder) }
        report(res, ok: "cloned \(repo.name)")
        refreshClonedStatus(for: account)
        await refreshStatuses(for: account, refreshRemote: true)
    }

    func pull(_ repo: Repo) async {
        guard let account = selectedAccount else { return }
        let path = localPath(repo, in: account)
        appendLog("Pulling \(repo.name)…")
        let res = await run { GitHub.pull(at: path) }
        report(res, ok: "pulled \(repo.name)")
        if !res.ok {
            pullWarning = PullWarning(
                repoName: repo.name,
                message: PullWarning.message(repoName: repo.name, gitOutput: res.stdout + res.stderr)
            )
        }
        await refreshStatuses(for: account, refreshRemote: true)
    }

    func push(_ repo: Repo) async {
        guard let account = selectedAccount else { return }
        let path = localPath(repo, in: account)
        appendLog("Pushing \(repo.name)…")
        let res = await run { GitHub.push(at: path) }
        report(res, ok: "pushed \(repo.name)")
        await refreshStatuses(for: account, refreshRemote: true)
    }

    func openGitHubProfile(_ account: Account) {
        guard let url = URL(string: "https://github.com/\(account.alias)") else { return }
        appendLog("Opening github.com/\(account.alias) in browser…")
        NSWorkspace.shared.open(url)
    }

    func openGitHubRepo(_ repo: Repo) {
        guard let url = URL(string: repo.url) else { return }
        appendLog("Opening \(repo.nameWithOwner) on GitHub in browser…")
        NSWorkspace.shared.open(url)
    }

    /// Starts `gh auth login --web` and then refreshes auth state shown in UI.
    func reauthenticateGh(for account: Account) async {
        appendLog("Opening GitHub device login page for \(account.alias)…")
        if let deviceURL = URL(string: "https://github.com/login/device") {
            NSWorkspace.shared.open(deviceURL)
        }
        appendLog("Starting gh auth login (web) for \(account.alias)…")
        currentAuthFlowCode = nil
        let clipboardWatcher = Task { await watchClipboardForDeviceCode() }
        let login = await run { GitHub.authLoginWebWithClipboard() }
        clipboardWatcher.cancel()
        let authOutput = (login.stdout + login.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = extractDeviceCode(from: authOutput) {
            if currentAuthFlowCode != code {
                appendLog("One-time code: \(code) (also copied to clipboard)")
                currentAuthFlowCode = code
            }
        }
        if login.ok {
            appendLog("✓ gh auth login completed.")
        } else {
            appendLog("✗ gh auth login failed: \(authOutput.isEmpty ? "unknown error" : authOutput)")
            appendLog("If prompted, paste the one-time code already copied to clipboard.")
            return
        }

        // Best effort: make the requested account active for subsequent operations.
        let switched = await ghSerialized { GitHub.ensureActiveAccount(account.alias) }
        if switched.ok {
            appendLog("✓ Active gh account set to \(account.alias).")
        } else {
            let out = (switched.stdout + switched.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            appendLog("⚠ Could not switch to \(account.alias): \(out)")
        }
        beginAccountStatusChecks([account], force: true)
        await logAuthStatus()
    }

    func openLocalFolder(_ repo: Repo) {
        guard let account = selectedAccount else { return }
        let path = localPath(repo, in: account)
        guard FileManager.default.fileExists(atPath: path) else {
            appendLog("✗ folder not found: \(path)")
            return
        }
        appendLog("Opening \(repo.name) folder…")
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Open a cloned repo's folder in the user's chosen GUI editor. Runs `open -a`
    /// off the main actor and logs a friendly message if the editor can't open.
    func openInEditor(_ repo: Repo, editor: PreferredEditor, customAppName: String) async {
        guard editor != .none, let account = selectedAccount else { return }
        let path = localPath(repo, in: account)
        guard FileManager.default.fileExists(atPath: path) else {
            appendLog("✗ folder not found: \(path)")
            return
        }
        let result: Result<String, EditorOpenError> = await run {
            do {
                let name = try EditorLauncher.open(path: path, editor: editor, customAppName: customAppName)
                return .success(name)
            } catch let error as EditorOpenError {
                return .failure(error)
            } catch {
                return .failure(.launchFailed(error.localizedDescription))
            }
        }
        switch result {
        case .success(let name):
            appendLog("Opening \(repo.name) in \(name)…")
        case .failure(let error):
            appendLog("✗ \(EditorLauncher.message(for: error))")
        }
    }

    /// Open a cloned repo's folder in the user's chosen GUI terminal. Runs `open -a`
    /// off the main actor and logs a friendly message if the terminal can't open.
    func openInTerminal(_ repo: Repo, terminal: PreferredTerminal, customAppName: String) async {
        guard terminal != .none, let account = selectedAccount else { return }
        let path = localPath(repo, in: account)
        guard FileManager.default.fileExists(atPath: path) else {
            appendLog("✗ folder not found: \(path)")
            return
        }
        let result: Result<String, TerminalOpenError> = await run {
            do {
                let name = try TerminalLauncher.open(path: path, terminal: terminal, customAppName: customAppName)
                return .success(name)
            } catch let error as TerminalOpenError {
                return .failure(error)
            } catch {
                return .failure(.launchFailed(error.localizedDescription))
            }
        }
        switch result {
        case .success(let name):
            appendLog("Opening \(repo.name) in \(name)…")
        case .failure(let error):
            appendLog("✗ \(TerminalLauncher.message(for: error))")
        }
    }

    /// Load the detailed changed-file list for a repo on demand (for the summary
    /// popover). Kept out of the interval scan, which only tracks counts. Reports a
    /// friendly error when the repo isn't cloned or git fails.
    func changedFiles(for repo: Repo) async -> Result<[GitFileChange], GitHubError> {
        guard let account = selectedAccount else {
            return .failure(GitHubError(message: "No account selected."))
        }
        let path = localPath(repo, in: account)
        let gitDir = (path as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else {
            return .failure(GitHubError(message: "This repository isn't cloned locally."))
        }
        return await run { GitHub.changedFiles(at: path) }
    }

    /// Move the local clone to Trash (does NOT touch the GitHub repo).
    func deleteLocalFolder(_ repo: Repo) async {
        guard let account = selectedAccount else { return }
        let path = localPath(repo, in: account)
        appendLog("Moving \(repo.name) folder to Trash…")
        let res = await run { FileOps.moveToTrash(path) }
        report(res, ok: "moved \(repo.name) to Trash")
        refreshClonedStatus(for: account)
        await refreshStatuses(for: account)
    }

    func commit(_ repo: Repo, message: String) async {
        guard let account = selectedAccount,
              !message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let path = localPath(repo, in: account)
        appendLog("Committing \(repo.name): “\(message)”…")
        let res = await run { GitHub.commitAll(at: path, message: message) }
        report(res, ok: "committed \(repo.name)")
        await refreshStatuses(for: account)
    }

    func initProject(_ plan: ProjectInitPlan,
                     visibility: RepoVisibilityChoice,
                     moveOriginalToTrash: Bool = false) async -> Bool {
        isInitializingProject = true
        appendLog("Initializing \(plan.repoName) for \(plan.account.alias)…")
        let res = await ghSerialized { GitHub.initAndPushProject(plan, visibility: visibility) }
        isInitializingProject = false
        report(res, ok: "initialized and pushed \(plan.account.alias)/\(plan.repoName)")
        if res.ok, plan.willCopy, moveOriginalToTrash {
            appendLog("Moving original folder to Trash…")
            let trash = await run { FileOps.moveToTrash(plan.sourcePath) }
            report(trash, ok: "moved original \(plan.sourceName) to Trash")
        }
        refreshClonedStatus(for: plan.account)
        await refreshStatuses(for: plan.account, refreshRemote: true)
        return res.ok
    }

    // MARK: Add-account wizard

    /// Alias for the in-progress account (GitHub login, lowercased).
    var addAccountAlias: String? { addAccountIdentity?.alias }

    func beginAddAccount() {
        addAccountSessionID = UUID()
        addAccountStep = .signIn
        addAccountBusy = false
        addAccountError = nil
        addAccountDeviceCode = nil
        addAccountIdentity = nil
        addAccountEmail = ""
        addAccountFolder = nil
        addAccountPublicKey = nil
        addAccountKeyCreated = false
        addAccountVerification = nil
        addAccountActive = true
    }

    func cancelAddAccount() {
        // If verification already ran, the config was written — refresh so the new
        // account's cards/chips populate, just like the Done path (minus the select).
        let wroteConfig = addAccountVerification != nil
        addAccountSessionID = UUID()
        addAccountActive = false
        addAccountBusy = false
        if wroteConfig { refreshAll() }
    }

    private func isCurrentAddAccountSession(_ session: UUID) -> Bool {
        addAccountActive && addAccountSessionID == session
    }

    /// Step 1 — open GitHub device login, surface the one-time code, then read the
    /// signed-in identity. gh work runs through the serialized chain so a stray
    /// background sweep can't flip the active account mid-flow.
    func addAccountSignIn() async {
        let session = addAccountSessionID
        addAccountBusy = true
        addAccountError = nil
        addAccountDeviceCode = nil
        appendLog("Add account: starting GitHub sign-in…")
        if let url = URL(string: "https://github.com/login/device") {
            NSWorkspace.shared.open(url)
        }
        let watcher = Task { await watchClipboardForAddAccountCode(session: session) }
        let result = await ghSerialized { () -> AddAccountLoginResult in
            let login = GitHub.authLoginWebWithClipboard()
            guard login.ok else { return AddAccountLoginResult(login: login, identity: nil) }
            return AddAccountLoginResult(login: login, identity: AccountSetup.currentIdentity())
        }
        watcher.cancel()
        guard isCurrentAddAccountSession(session) else { return }
        let out = (result.login.stdout + result.login.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = extractDeviceCode(from: out) { addAccountDeviceCode = code }
        guard result.login.ok else {
            addAccountError = "Sign-in failed: \(out.isEmpty ? "unknown error" : out)"
            addAccountBusy = false
            return
        }
        guard let identity = result.identity else {
            addAccountError = "Could not read account after sign-in."
            addAccountBusy = false
            return
        }
        switch identity {
        case .success(let id):
            if accounts.contains(where: { $0.alias.caseInsensitiveCompare(id.alias) == .orderedSame }) {
                addAccountError = "\(id.login) is already set up in this app."
                addAccountBusy = false
                return
            }
            addAccountIdentity = id
            addAccountEmail = id.noreplyEmail
            appendLog("Add account: signed in as \(id.login).")
            addAccountStep = .folder
        case .failure(let e):
            addAccountError = "Could not read account: \(e.message)"
        }
        addAccountBusy = false
    }

    func setAddAccountFolder(_ path: String) { addAccountFolder = path }

    /// Step 2 → 3 — generate (or reuse) the dedicated SSH key, then show its pubkey.
    func addAccountGenerateKey() async {
        guard let id = addAccountIdentity else { return }
        let session = addAccountSessionID
        addAccountBusy = true
        addAccountError = nil
        let alias = id.alias
        let comment = addAccountEmail.isEmpty ? alias : addAccountEmail
        let result = await run({ AccountSetup.ensureKey(alias: alias, comment: comment) })
        guard isCurrentAddAccountSession(session) else { return }
        switch result {
        case .success(let r):
            addAccountPublicKey = r.publicKey
            addAccountKeyCreated = r.created
            appendLog(r.created
                      ? "Add account: generated SSH key id_\(alias)."
                      : "Add account: reusing existing SSH key id_\(alias).")
            addAccountStep = .sshKey
        case .failure(let e):
            addAccountError = "SSH key error: \(e.message)"
        }
        addAccountBusy = false
    }

    /// Step 4 — write config (with backups) and verify. Stays on `.finish`; the
    /// sheet shows the verify result and a Done button.
    func addAccountFinish() async {
        guard let id = addAccountIdentity, let folder = addAccountFolder else { return }
        let session = addAccountSessionID
        addAccountBusy = true
        addAccountError = nil
        let alias = id.alias
        appendLog("Add account: writing config for \(alias) (backups first)…")

        let sshWrite = await run({ AccountSetup.ensureSSHConfig(alias: alias) })
        guard isCurrentAddAccountSession(session) else { return }
        switch sshWrite {
        case .success(let result):
            if let backup = result.backupPath { appendLog("Add account: backed up ~/.ssh/config -> \(backup).") }
            if result.wroteBlock { appendLog("Add account: added ~/.ssh/config host github-\(alias).") }
        case .failure(let e):
            addAccountError = e.message; addAccountBusy = false; return
        }

        let name = id.displayName
        let email = addAccountEmail
        let write = await run { AccountSetup.writeGitConfig(alias: alias, name: name, email: email, folder: folder) }
        guard isCurrentAddAccountSession(session) else { return }
        if case .failure(let e) = write {
            addAccountError = e.message; addAccountBusy = false; return
        }
        if case .success(let result) = write {
            if let backup = result.accountGitconfigBackupPath { appendLog("Add account: backed up account gitconfig -> \(backup).") }
            if let backup = result.globalGitconfigBackupPath { appendLog("Add account: backed up ~/.gitconfig -> \(backup).") }
        }
        appendLog("Add account: wrote gitconfig + includeIf, created \(folder).")

        await addAccountReverify()
        accounts = orderedAccounts(GitConfig.loadAccounts())
        addAccountBusy = false
    }

    /// Re-run SSH/gh verification (handy right after pasting the key, which can take
    /// a moment to propagate on GitHub's side).
    func addAccountReverify() async {
        guard let alias = addAccountAlias else { return }
        let session = addAccountSessionID
        let result = await ghSerialized { AccountSetup.verify(alias: alias) }
        guard isCurrentAddAccountSession(session) else { return }
        addAccountVerification = result
        let sshText = result.sshOK ? "OK" : (result.sshLogin.map { "as \($0), expected \(alias)" } ?? "not ready")
        let ghText = result.ghOK ? "OK" : (result.ghLogin.map { "as \($0), expected \(alias)" } ?? "unknown")
        appendLog("Add account: verify — SSH \(sshText), gh \(ghText).")
    }

    /// Close the wizard, refresh everything, and select the new account.
    func completeAddAccount() {
        let newAlias = addAccountAlias
        addAccountSessionID = UUID()
        addAccountActive = false
        refreshAll()
        if let newAlias, let acct = accounts.first(where: { $0.alias.caseInsensitiveCompare(newAlias) == .orderedSame }) {
            selectAccount(acct)
        }
    }

    private func watchClipboardForAddAccountCode(session: UUID) async {
        for _ in 0..<240 { // ~120s
            if Task.isCancelled || !isCurrentAddAccountSession(session) { return }
            if let clip = NSPasteboard.general.string(forType: .string),
               let code = extractDeviceCode(from: clip) {
                addAccountDeviceCode = code
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: Logging

    private func report(_ res: ShellResult, ok: String) {
        let out = (res.stdout + res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if res.ok {
            appendLog("✓ \(ok)" + (out.isEmpty ? "" : "\n\(out)"))
        } else {
            appendLog("✗ \(out.isEmpty ? "failed" : out)")
        }
    }

    /// Cap the Output log so an always-open session stays flat in memory.
    private static let maxLogLines = 500

    private func appendLog(_ s: String) {
        log += s + "\n"
        // Marker is always at the start of the message, even when the body spans
        // several lines, so this stays correct for multi-line error output.
        lastLogWasError = s.hasPrefix("✗") || s.hasPrefix("⚠")
        enforceLogLimit()
    }

    /// Keep only the most recent `maxLogLines` lines. Counts real lines, so it
    /// handles multi-line entries (e.g. command output) correctly.
    private func enforceLogLimit() {
        var lines = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }   // drop the empty tail from the final "\n"
        guard lines.count > Self.maxLogLines else { return }
        log = lines.suffix(Self.maxLogLines).joined(separator: "\n") + "\n"
    }

    /// Poll clipboard while auth flow runs so the code can be shown immediately.
    private func watchClipboardForDeviceCode() async {
        for _ in 0..<120 { // up to ~60 seconds
            if Task.isCancelled { return }
            if let clip = NSPasteboard.general.string(forType: .string),
               let code = extractDeviceCode(from: clip),
               currentAuthFlowCode != code {
                appendLog("One-time code: \(code) (also copied to clipboard)")
                currentAuthFlowCode = code
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Extracts the GitHub device code printed by `gh auth login --web`.
    /// Example line: "First copy your one-time code: 57C6-CEA6"
    private func extractDeviceCode(from text: String) -> String? {
        let nsText = text as NSString
        let pattern = #"([A-Z0-9]{4}-[A-Z0-9]{4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else { return nil }
        return nsText.substring(with: match.range(at: 1)).uppercased()
    }

    private func sanitizedRepoName(from folderName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = folderName.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        var name = String(scalars)
        while name.contains("--") {
            name = name.replacingOccurrences(of: "--", with: "-")
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return name.isEmpty ? "new-repo" : name
    }

    /// Run blocking shell work off the main actor; result lands back on the main actor.
    private func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }
}

/// Forgiving "wild" matching for the repo search bar.
///
/// Each whitespace-separated token must match somewhere in the repo's name,
/// owner/name, or description. A token matches when it is a plain substring,
/// a fuzzy subsequence (e.g. `mgm` → `multi-git-manager`), or a glob pattern
/// using `*` (any run) and `?` (single char).
enum RepoSearch {
    static func matches(query: String, repo: Repo) -> Bool {
        let haystacks = [repo.name, repo.nameWithOwner, repo.description ?? ""]
            .map { $0.lowercased() }
        let tokens = query.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            haystacks.contains { tokenMatches(token, in: $0) }
        }
    }

    private static func tokenMatches(_ token: String, in hay: String) -> Bool {
        if token.contains("*") || token.contains("?") {
            return glob(Array(token), Array(hay))
        }
        if hay.contains(token) { return true }
        return isSubsequence(token, of: hay)
    }

    /// Classic iterative wildcard matcher with backtracking.
    private static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0, star = -1, mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1; t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p; mark = t; p += 1
            } else if star != -1 {
                p = star + 1; mark += 1; t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    /// True when every character of `needle` appears in `hay` in order.
    private static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var idx = hay.startIndex
        for ch in needle {
            var found = false
            while idx < hay.endIndex {
                let cur = hay[idx]
                idx = hay.index(after: idx)
                if cur == ch { found = true; break }
            }
            if !found { return false }
        }
        return true
    }
}

/// Same forgiving matcher as repo search, applied to account card fields.
enum AccountSearch {
    static func matches(query: String, account: Account) -> Bool {
        let haystacks = [
            account.alias,
            account.name,
            account.email,
            account.folder,
            account.sshHost
        ].map { $0.lowercased() }
        let tokens = query.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            haystacks.contains { tokenMatches(token, in: $0) }
        }
    }

    private static func tokenMatches(_ token: String, in hay: String) -> Bool {
        if token.contains("*") || token.contains("?") {
            return glob(Array(token), Array(hay))
        }
        if hay.contains(token) { return true }
        return isSubsequence(token, of: hay)
    }

    private static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0, star = -1, mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1; t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p; mark = t; p += 1
            } else if star != -1 {
                p = star + 1; mark += 1; t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    private static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var idx = hay.startIndex
        for ch in needle {
            var found = false
            while idx < hay.endIndex {
                let cur = hay[idx]
                idx = hay.index(after: idx)
                if cur == ch { found = true; break }
            }
            if !found { return false }
        }
        return true
    }
}
