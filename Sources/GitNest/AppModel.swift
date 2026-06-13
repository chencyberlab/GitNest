import SwiftUI
import AppKit
import Combine

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

    struct RepoFolderConflict: Sendable, Equatable {
        let path: String
        let origin: String?

        var message: String {
            if let origin, !origin.isEmpty {
                return """
                Target folder already contains a different Git repo:
                \(path)

                origin: \(origin)

                Move or rename that folder before cloning this repository.
                """
            }
            return """
            Target path already exists, but it is not this GitHub repository:
            \(path)

            Move or rename that folder before cloning this repository.
            """
        }

        var shortHelp: String {
            if let origin, !origin.isEmpty {
                return "Folder occupied by a different repo: \(origin)"
            }
            return "Folder occupied by something that is not this repo"
        }
    }

    enum LocalRepoFolderState: Sendable, Equatable {
        case absent
        case cloned
        case occupied(RepoFolderConflict)
    }

    struct AddAccountLoginResult: Sendable {
        let login: ShellResult
        let identity: Result<AccountSetup.Identity, CommandError>?
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
    /// This is a cached derivative of `repos`, `repoSearch`, `repoSortField`,
    /// `repoSortAscending`, and `clonedRepos`; it is recomputed only when one of
    /// those inputs changes, avoiding O(n log n) work on every view update.
    @Published var filteredRepos: [Repo] = []
    private var filteredReposCancellable: AnyCancellable?

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
    }
    @Published var sshGreetings: [String: String] = [:]   // alias -> "Hi X!"
    @Published var ghIndicators: [String: GhAuthIndicator] = [:] // alias -> gh auth status
    @Published var accountStatusChecksPending: Set<String> = []
    @Published var isLoadingRepos = false
    @Published var isRefreshingRepos = false
    @Published var isCheckingRepoRemotes = false
    @Published var repoRefreshMessage: String?
    @Published var isInitializingProject = false
    @Published var isForkingProject = false
    /// Repos with a mutating local action in flight, so the row can disable its
    /// buttons and a double-click can't run two operations on the same repo. Rows
    /// that share a local folder are marked busy together; `busyRepoPaths` is the
    /// backend guard for rows that appear after a refresh while work is in flight.
    @Published var busyRepos: Set<Repo.ID> = []
    var busyRepoPaths: Set<String> = []
    @Published var log: String = ""
    /// Whether the most recently appended log line was a failure/warning. The
    /// collapsed Output status line uses this to stay pinned on problems while
    /// progress/success lines fade away on their own.
    @Published var lastLogWasError = false
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
    @Published var clonedRepos: Set<Repo.ID> = []   // repo owner/name values present on disk for the selected account
    @Published var repoStatuses: [Repo.ID: RepoStatus] = [:]   // repo owner/name -> local/upstream state
    @Published var repoFolderConflicts: [Repo.ID: RepoFolderConflict] = [:]
    var currentAuthFlowCode: String?
    var repoCache: [String: [Repo]] = [:]
    var clonedReposCache: [String: Set<Repo.ID>] = [:]
    var repoStatusesCache: [String: [Repo.ID: RepoStatus]] = [:]
    var repoFolderConflictsCache: [String: [Repo.ID: RepoFolderConflict]] = [:]
    var repoSearchCache: [String: String] = [:]
    var selectedRepoCache: [String: Repo.ID] = [:]
    var repoLoadsInFlight: Set<String> = []
    var repoAutoRefreshAccounts: Set<String> = []
    var repoLastRefreshAt: [String: Date] = [:]
    var lifecycleStarted = false
    var addAccountSessionID = UUID()
    /// The in-flight `gh auth login --web` process, if any, so cancelling the
    /// Add-account wizard (or starting another sign-in) can kill its GitHub poll
    /// instead of leaving it to block the serialized gh chain for minutes.
    var activeAuthProcess: Shell.ProcessHandle?
    var accountStatusSessionID = UUID()
    var accountStatusLoadMode: AccountStatusLoadMode = .smart
    static let accountOrderDefaultsKey = "accountOrder"

    /// Seconds between automatic rescans of cloned-repo status. Change here to tune.
    static let statusRefreshSeconds: UInt64 = 10
    var statusTimer: Task<Void, Never>?
    var repoAutoRefreshTimer: Task<Void, Never>?
    var repoAutoRefreshSeconds: UInt64 = 5 * 60

    /// Accounts you're not currently viewing refresh no more often than this,
    /// regardless of the chosen interval — the on-switch refresh keeps them instant
    /// when you actually open them. Bounds background polling cost across accounts.
    static let backgroundRefreshFloorSeconds: UInt64 = 5 * 60

    /// Whether the app is currently the active application. Auto-refresh timers
    /// are paused while the app is in the background to avoid unnecessary CPU,
    /// network, and GitHub API usage.
    @Published var appIsActive = true
    private var workspaceObservers: [any NSObjectProtocol] = []

    /// How long the "Repos refreshed just now." confirmation lingers before it
    /// auto-clears, plus the task that performs that delayed clear.
    static let refreshMessageLingerSeconds: UInt64 = 10
    var repoRefreshMessageDismiss: Task<Void, Never>?

    /// Tail of the serialized gh-account work chain. `gh`'s active account is
    /// global on-disk state, so the indicator sweep, repo listing, and project
    /// init must not interleave their switch+use steps — one would flip the
    /// active account out from under another. Routing them through this chain
    /// makes those sections run one at a time, in call order.
    var ghChain: Task<Void, Never> = Task {}

    func ghSerialized<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let previous = ghChain
        let task = Task<T, Never> {
            _ = await previous.value
            return await Self.runBlocking(work)
        }
        ghChain = Task { _ = await task.value }
        return await task.value
    }

    func ghSerializedPreservingActiveAccount<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await ghSerialized {
            let original = GitHub.currentLogin()
            let result = work()
            if let original, !original.isEmpty {
                GitHub.switchTo(original)
            }
            return result
        }
    }

    func startAuthProcess() -> Shell.ProcessHandle {
        activeAuthProcess?.cancel()
        let process = Shell.ProcessHandle()
        activeAuthProcess = process
        return process
    }

    func finishAuthProcess(_ process: Shell.ProcessHandle) {
        if activeAuthProcess === process { activeAuthProcess = nil }
    }

    deinit {
        statusTimer?.cancel()
        repoAutoRefreshTimer?.cancel()
        repoRefreshMessageDismiss?.cancel()
        for observer in workspaceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    init() {
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

    func configureAccountStatusLoadMode(_ mode: AccountStatusLoadMode) {
        accountStatusLoadMode = mode
    }

    func startLifecycle(statusMode: AccountStatusLoadMode, repoAutoRefreshSeconds: Int) {
        configureAccountStatusLoadMode(statusMode)
        observeAppActivation()
        if !lifecycleStarted {
            lifecycleStarted = true
            refreshAll(statusMode: statusMode)
            startStatusAutoRefresh()
        } else {
            startStatusAutoRefresh()
        }
        configureRepoAutoRefresh(seconds: repoAutoRefreshSeconds)
    }

    /// Pause/resume auto-refresh timers when the app moves to/from the background.
    /// Comparing `processIdentifier` avoids relying on the bundle identifier, which
    /// may differ between a manually assembled .app and `swift run`.
    private func observeAppActivation() {
        guard workspaceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == NSRunningApplication.current.processIdentifier else { return }
            Task { @MainActor in
                self.appIsActive = true
                self.resumeAutoRefresh()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == NSRunningApplication.current.processIdentifier else { return }
            Task { @MainActor in
                self.appIsActive = false
                self.pauseAutoRefresh()
            }
        })
    }

    private func pauseAutoRefresh() {
        statusTimer?.cancel()
        statusTimer = nil
        repoAutoRefreshTimer?.cancel()
        repoAutoRefreshTimer = nil
    }

    private func resumeAutoRefresh() {
        startStatusAutoRefresh()
        configureRepoAutoRefresh(seconds: Int(repoAutoRefreshSeconds))
        // Refresh the visible account immediately so the UI is current after
        // the app returns to the foreground.
        Task { [weak self] in
            guard let self, let account = self.selectedAccount else { return }
            if !self.repos.isEmpty {
                await self.refreshStatuses(for: account)
            }
            if self.shouldAutoRefreshRepos(for: account.alias) {
                await self.loadRepos(for: account, silent: true, userInitiated: false)
            }
        }
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

    func orderedAccounts(_ loaded: [Account]) -> [Account] {
        let savedOrder = UserDefaults.standard.stringArray(forKey: Self.accountOrderDefaultsKey) ?? []
        // A saved order can carry duplicate aliases (older builds, or a hand-edited
        // defaults file) — keep the first position for each so this never traps.
        let orderIndex = Dictionary(savedOrder.enumerated().map { ($0.element, $0.offset) },
                                    uniquingKeysWith: { first, _ in first })
        return loaded.enumerated()
            .sorted { lhs, rhs in
                let left = orderIndex[lhs.element.alias] ?? Int.max
                let right = orderIndex[rhs.element.alias] ?? Int.max
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func saveAccountOrder() {
        UserDefaults.standard.set(accounts.map(\.alias), forKey: Self.accountOrderDefaultsKey)
    }

    func saveVisibleRepoState() {
        guard let alias = selectedAccount?.alias else { return }
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

    func restoreRepoState(for account: Account) {
        let alias = account.alias
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

    // MARK: Logging

    func report(_ res: ShellResult, ok: String) {
        let out = (res.stdout + res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if res.ok {
            appendLog("✓ \(ok)" + (out.isEmpty ? "" : "\n\(out)"))
        } else {
            appendLog("✗ \(out.isEmpty ? "failed" : out)")
        }
    }

    /// Cap the Output log so an always-open session stays flat in memory.
    static let maxLogLines = 500

    func appendLog(_ s: String) {
        log += s + "\n"
        // Marker is always at the start of the message, even when the body spans
        // several lines, so this stays correct for multi-line error output.
        lastLogWasError = s.hasPrefix("✗") || s.hasPrefix("⚠")
        enforceLogLimit()
    }

    /// Keep only the most recent `maxLogLines` lines. Counts real lines, so it
    /// handles multi-line entries (e.g. command output) correctly.
    func enforceLogLimit() {
        var lines = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }   // drop the empty tail from the final "\n"
        guard lines.count > Self.maxLogLines else { return }
        log = lines.suffix(Self.maxLogLines).joined(separator: "\n") + "\n"
    }

    /// Watch the clipboard for a GitHub device code while an auth flow runs.
    /// Only reads the pasteboard when its `changeCount` advances, so it does not
    /// repeatedly trigger macOS clipboard-privacy alerts.
    func watchClipboardForDeviceCode(after startingChangeCount: Int) async {
        var lastChangeCount = startingChangeCount
        for _ in 0..<120 { // up to ~60 seconds
            if Task.isCancelled { return }
            let current = NSPasteboard.general.changeCount
            if current != lastChangeCount {
                lastChangeCount = current
                if let clip = NSPasteboard.general.string(forType: .string),
                   let code = DeviceCode.extract(fromClipboard: clip),
                   currentAuthFlowCode != code {
                    appendLog("One-time code: \(code) (also copied to clipboard)")
                    currentAuthFlowCode = code
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func sanitizedRepoName(from folderName: String) -> String {
        // GitHub repo names are ASCII [A-Za-z0-9._-]. CharacterSet.alphanumerics is
        // Unicode-aware, so it would pass "héllo" through unchanged — which gh
        // rejects (or GitHub silently renames, desyncing repoFullName).
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        var name = String(folderName.map { allowed.contains($0) ? $0 : "-" })
        while name.contains("--") {
            name = name.replacingOccurrences(of: "--", with: "-")
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        if name.count > 100 { name = String(name.prefix(100)) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return name.isEmpty ? "new-repo" : name
    }

    nonisolated static func localFolderState(for repo: Repo, path: String) -> LocalRepoFolderState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .absent }

        let git = (path as NSString).appendingPathComponent(".git")
        guard fm.fileExists(atPath: git) else {
            return .occupied(RepoFolderConflict(path: path, origin: nil))
        }

        let origin = GitHub.originURL(at: path)
        if let origin, GitHub.remoteLooksLike(origin, owner: repo.owner, repoName: repo.name) {
            return .cloned
        }
        return .occupied(RepoFolderConflict(path: path, origin: origin))
    }

    /// Run blocking shell work off the main actor; result lands back on the main actor.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Self.runBlocking(work)
    }

    /// Shell commands block their thread on semaphores/`waitpid`/`waitUntilExit`.
    /// A `Task.detached` runs that on Swift's cooperative thread pool, which is only
    /// ~CPU-core wide — a few concurrent commands (pull on several repos while timers
    /// tick) could park every pool thread and stall unrelated async work. Dispatch to
    /// a dedicated concurrent queue instead so those waits never touch the pool.
    static let blockingQueue = DispatchQueue(label: "org.gitnest.shell",
                                                     qos: .userInitiated,
                                                     attributes: .concurrent)

    static func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            blockingQueue.async { continuation.resume(returning: work()) }
        }
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
        WildcardMatcher.matches(
            query: query,
            haystacks: [repo.name, repo.nameWithOwner, repo.description ?? ""]
        )
    }
}

/// Same forgiving matcher as repo search, applied to account card fields.
enum AccountSearch {
    static func matches(query: String, account: Account) -> Bool {
        WildcardMatcher.matches(
            query: query,
            haystacks: [
                account.alias,
                account.name,
                account.email,
                account.folder,
                account.sshHost
            ]
        )
    }
}

enum WildcardMatcher {
    static func matches(query: String, haystacks rawHaystacks: [String]) -> Bool {
        let haystacks = rawHaystacks.map { $0.lowercased() }
        let tokens = query.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            haystacks.contains { tokenMatches(token, in: $0) }
        }
    }

    static func tokenMatches(_ token: String, in hay: String) -> Bool {
        if token.contains("*") || token.contains("?") {
            return glob(Array(token), Array(hay))
        }
        if hay.contains(token) { return true }
        return isSubsequence(token, of: hay)
    }

    /// Classic iterative wildcard matcher with backtracking.
    static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
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
    static func isSubsequence(_ needle: String, of hay: String) -> Bool {
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
