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
    @Published var accounts: [Account] = []
    @Published var selectedAccount: Account?
    @Published var sshGreetings: [String: String] = [:]
    @Published var ghIndicators: [String: AccountManager.GhAuthIndicator] = [:]
    @Published var accountStatusChecksPending: Set<String> = []

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

    /// Header click: same column flips direction; a new column resets to its
    /// natural default (names A→Z, dates newest-first).
    func sortBy(_ field: RepoSortField) {
        repoManager.sortBy(field)
    }

    @Published var isLoadingRepos = false
    @Published var isRefreshingRepos = false
    @Published var isCheckingRepoRemotes = false
    @Published var repoRefreshMessage: String?
    @Published var isInitializingProject = false
    @Published var isForkingProject = false
    @Published var log: String = ""
    /// Whether the most recently appended log line was a failure/warning. The
    /// collapsed Output status line uses this to stay pinned on problems while
    /// progress/success lines fade away on their own.
    @Published var lastLogWasError = false
    @Published var pullWarning: AlertStore.PullWarning?

    let ghChain: GhChain
    let logStore: LogStore
    let alertStore: AlertStore
    let accountManager: AccountManager
    let repoManager: RepoManager
    let repoActionCoordinator: RepoActionCoordinator
    let projectWorkflow: ProjectWorkflow
    let authProcessController: AuthProcessController
    let setupCoordinator: SetupCoordinator

    /// Add-account wizard state (driven by AddAccountSheet via setupCoordinator).
    @Published var addAccountActive = false
    @Published var clonedRepos: Set<Repo.ID> = []   // repo owner/name values present on disk for the selected account
    @Published var repoStatuses: [Repo.ID: RepoStatus] = [:]   // repo owner/name -> local/upstream state
    @Published var repoFolderConflicts: [Repo.ID: RepoFolderConflict] = [:]
    /// Mirror of `repoActionCoordinator.busyRepos`. Rows read the busy state through
    /// the coordinator but observe only `AppModel`, so this re-publish is what makes
    /// their action buttons disable/enable when an action starts or finishes.
    @Published var busyRepos: Set<Repo.ID> = []
    var lifecycleStarted = false
    static let accountOrderDefaultsKey = "accountOrder"

    /// Whether the app is currently the active application. Auto-refresh timers
    /// are paused while the app is in the background to avoid unnecessary CPU,
    /// network, and GitHub API usage.
    @Published var appIsActive = true
    private var workspaceObservers: [any NSObjectProtocol] = []

    deinit {
        for observer in workspaceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private var storeCancellables = Set<AnyCancellable>()

    init() {
        self.ghChain = GhChain()
        self.logStore = LogStore()
        self.alertStore = AlertStore()
        self.authProcessController = AuthProcessController()
        self.accountManager = AccountManager(ghChain: ghChain, logStore: logStore, authProcessController: authProcessController)
        self.repoManager = RepoManager(ghChain: ghChain, logStore: logStore, accountManager: accountManager)
        self.repoActionCoordinator = RepoActionCoordinator(repoManager: repoManager,
                                                           logStore: logStore,
                                                           alertStore: alertStore,
                                                           accountManager: accountManager)
        self.projectWorkflow = ProjectWorkflow(ghChain: ghChain, logStore: logStore, repoManager: repoManager)
        self.setupCoordinator = SetupCoordinator(ghChain: ghChain,
                                                 logStore: logStore,
                                                 accountManager: accountManager,
                                                 authProcessController: authProcessController)
        logStore.$log.assign(to: &$log)
        logStore.$lastWasError.assign(to: &$lastLogWasError)
        alertStore.$pullWarning.assign(to: &$pullWarning)
        accountManager.$accounts.assign(to: &$accounts)
        accountManager.$selectedAccount.assign(to: &$selectedAccount)
        accountManager.$sshGreetings.assign(to: &$sshGreetings)
        accountManager.$ghIndicators.assign(to: &$ghIndicators)
        accountManager.$accountStatusChecksPending.assign(to: &$accountStatusChecksPending)
        repoManager.$repos.assign(to: &$repos)
        repoManager.$repoSearch.assign(to: &$repoSearch)
        repoManager.$selectedRepo.assign(to: &$selectedRepo)
        repoManager.$repoSortField.assign(to: &$repoSortField)
        repoManager.$repoSortAscending.assign(to: &$repoSortAscending)
        repoManager.$filteredRepos.assign(to: &$filteredRepos)
        repoManager.$clonedRepos.assign(to: &$clonedRepos)
        repoManager.$repoStatuses.assign(to: &$repoStatuses)
        repoManager.$repoFolderConflicts.assign(to: &$repoFolderConflicts)
        repoManager.$isLoadingRepos.assign(to: &$isLoadingRepos)
        repoManager.$isRefreshingRepos.assign(to: &$isRefreshingRepos)
        repoManager.$isCheckingRepoRemotes.assign(to: &$isCheckingRepoRemotes)
        repoManager.$repoRefreshMessage.assign(to: &$repoRefreshMessage)
        repoActionCoordinator.$busyRepos.assign(to: &$busyRepos)
        projectWorkflow.$isInitializingProject.assign(to: &$isInitializingProject)
        projectWorkflow.$isForkingProject.assign(to: &$isForkingProject)
        setupCoordinator.$addAccountActive.assign(to: &$addAccountActive)
        bindAutoRefreshGate()
    }

    // MARK: - UI write intents
    //
    // `selectedRepo`, `repoSearch`, and `addAccountActive` are one-way mirrors
    // of their owning managers (see the `assign(to:)` wiring in `init`). The UI
    // reads the mirror but must write through to the source of truth, so route
    // writes here rather than mutating the mirror. Mutating the mirror would not
    // propagate to the manager, and the previous two-way Combine bindings that
    // tried to bridge it caused an infinite `willSet` feedback loop that crashed
    // the app with a stack overflow.

    func selectRepo(_ id: Repo.ID?) {
        repoManager.selectedRepo = id
    }

    func setRepoSearch(_ text: String) {
        repoManager.repoSearch = text
    }

    func dismissPullWarning() {
        alertStore.dismissPullWarning()
    }

    /// Two-way binding for the search field: reads the mirror, writes the source.
    var repoSearchBinding: Binding<String> {
        Binding(get: { self.repoSearch }, set: { self.repoManager.repoSearch = $0 })
    }

    /// Two-way binding for the add-account sheet: reads the mirror, writes the source.
    var addAccountActiveBinding: Binding<Bool> {
        Binding(
            get: { self.addAccountActive },
            set: { isPresented in
                if isPresented {
                    self.setupCoordinator.addAccountActive = true
                } else if self.setupCoordinator.addAccountActive {
                    self.setupCoordinator.cancelAddAccount()
                }
            }
        )
    }

    private func bindAutoRefreshGate() {
        Publishers
            .CombineLatest3($isInitializingProject, $isForkingProject, $addAccountActive)
            .sink { [weak self] initializing, forking, adding in
                self?.repoManager.canAutoRefresh = !initializing && !forking && !adding
            }
            .store(in: &storeCancellables)
    }

    func configureAccountStatusLoadMode(_ mode: AccountStatusLoadMode) {
        accountManager.configureAccountStatusLoadMode(mode)
    }

    func logAuthStatus() async {
        await accountManager.logAuthStatus()
    }

    func configureRepoAutoRefresh(seconds: Int) {
        repoManager.configureRepoAutoRefresh(seconds: seconds, appIsActive: appIsActive)
    }

    func startLifecycle(statusMode: AccountStatusLoadMode, repoAutoRefreshSeconds: Int) {
        configureAccountStatusLoadMode(statusMode)
        observeAppActivation()
        if !lifecycleStarted {
            lifecycleStarted = true
            refreshAll(statusMode: statusMode)
            repoManager.startStatusAutoRefresh(appIsActive: appIsActive)
        } else {
            repoManager.startStatusAutoRefresh(appIsActive: appIsActive)
        }
        repoManager.configureRepoAutoRefresh(seconds: repoAutoRefreshSeconds, appIsActive: appIsActive)
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
                self.repoManager.appIsActive = true
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
                self.repoManager.appIsActive = false
                self.pauseAutoRefresh()
            }
        })
    }

    private func pauseAutoRefresh() {
        repoManager.stopStatusAutoRefresh()
        repoManager.stopRepoAutoRefresh()
    }

    private func resumeAutoRefresh() {
        repoManager.startStatusAutoRefresh(appIsActive: appIsActive)
        repoManager.configureRepoAutoRefresh(seconds: Int(repoManager.repoAutoRefreshSeconds), appIsActive: appIsActive)
        // Refresh the visible account immediately so the UI is current after
        // the app returns to the foreground.
        Task { [weak self] in
            guard let self, let account = self.selectedAccount else { return }
            if !self.repos.isEmpty {
                await self.repoManager.refreshStatuses(for: account)
            }
            if self.repoManager.shouldAutoRefreshRepos(for: account.alias) {
                await self.repoManager.loadRepos(for: account, silent: true, userInitiated: false)
            }
        }
    }

    func refreshAll(statusMode: AccountStatusLoadMode? = nil, manual: Bool = false) {
        accountManager.refreshAll(statusMode: statusMode, manual: manual)
    }

    /// Account switch UX: show cached repos immediately if they exist.
    /// Repo listing itself remains user-driven via the Load repos button.
    func selectAccount(_ account: Account) {
        repoManager.saveVisibleRepoState()
        accountManager.selectAccount(account)
        repoManager.restoreRepoState(for: account)
        if repoManager.repoAutoRefreshAccounts.contains(account.alias),
           repoManager.shouldAutoRefreshRepos(for: account.alias) {
            Task { await repoManager.loadRepos(for: account, silent: true, userInitiated: false) }
        }
    }

    /// Move `alias` to an absolute index in the full account list (clamped to the
    /// valid range). Used by drag-to-reorder, which computes a precise drop slot.
    /// No-ops when the order wouldn't change.
    func moveAccount(alias: String, toIndex index: Int) {
        accountManager.moveAccount(alias: alias, toIndex: index)
    }

    func orderedAccounts(_ loaded: [Account]) -> [Account] {
        accountManager.orderedAccounts(loaded)
    }

    func saveAccountOrder() {
        accountManager.saveAccountOrder()
    }

    func saveVisibleRepoState() {
        repoManager.saveVisibleRepoState()
    }

    func restoreRepoState(for account: Account) {
        repoManager.restoreRepoState(for: account)
    }

    // MARK: Logging

    func report(_ res: ShellResult, ok: String) {
        logStore.report(res, ok: ok)
    }

    func appendLog(_ s: String) {
        logStore.append(s)
    }

    nonisolated static func localFolderState(for repo: Repo,
                                             path: String,
                                             expectedSSHHost: String? = nil) -> LocalRepoFolderState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .absent }

        let git = (path as NSString).appendingPathComponent(".git")
        guard fm.fileExists(atPath: git) else {
            return .occupied(RepoFolderConflict(path: path, origin: nil))
        }

        let origin = GitHub.originURL(at: path)
        if let origin,
           GitHub.remoteLooksLike(origin,
                                  owner: repo.owner,
                                  repoName: repo.name,
                                  expectedSSHHost: expectedSSHHost) {
            return .cloned
        }
        return .occupied(RepoFolderConflict(path: path, origin: origin))
    }

    /// Run blocking shell work off the main actor; result lands back on the main actor.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await runBlocking(work)
    }
}
