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
    let ghChain: GhChain
    let logStore: LogStore
    let alertStore: AlertStore
    let accountManager: AccountManager
    let repoManager: RepoManager
    let repoActionCoordinator: RepoActionCoordinator
    let projectWorkflow: ProjectWorkflow
    let authProcessController: AuthProcessController
    let setupCoordinator: SetupCoordinator

    var lifecycleStarted = false

    /// The `gh` account that was active when the app started. Captured as the
    /// first `ghChain` job in `startLifecycle` (before any account checks switch
    /// gh) and restored on termination so the app doesn't leave `gh` pointing at
    /// the last account it happened to switch to.
    private var initialGhLogin: String?

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
        bindAutoRefreshGate()
    }

    private func bindAutoRefreshGate() {
        Publishers
            .CombineLatest3(projectWorkflow.$isInitializingProject,
                            projectWorkflow.$isForkingProject,
                            setupCoordinator.$addAccountActive)
            .sink { [weak self] initializing, forking, adding in
                self?.repoManager.canAutoRefresh = !initializing && !forking && !adding
            }
            .store(in: &storeCancellables)
    }

    func configureAccountStatusLoadMode(_ mode: AccountStatusLoadMode) {
        accountManager.configureAccountStatusLoadMode(mode)
    }

    func configureRepoAutoRefresh(seconds: Int) {
        repoManager.configureRepoAutoRefresh(seconds: seconds, appIsActive: appIsActive)
    }

    func startLifecycle(statusMode: AccountStatusLoadMode, repoAutoRefreshSeconds: Int) {
        configureAccountStatusLoadMode(statusMode)
        observeAppActivation()
        if !lifecycleStarted {
            lifecycleStarted = true
            // Capture gh's pre-app active account as the chain's first job, then
            // start refresh work — never in parallel, or a fast quit could miss the
            // snapshot and account checks could run before it is recorded.
            Task { [weak self] in
                guard let self else { return }
                self.initialGhLogin = await self.ghChain.serialized { GitHub.currentLogin() }
                self.checkRequiredTools()
                self.accountManager.refreshAll(statusMode: statusMode)
                self.repoManager.startStatusAutoRefresh(appIsActive: self.appIsActive)
            }
        } else {
            repoManager.startStatusAutoRefresh(appIsActive: appIsActive)
        }
        repoManager.configureRepoAutoRefresh(seconds: repoAutoRefreshSeconds, appIsActive: appIsActive)
    }

    private func checkRequiredTools() {
        Task { [weak self] in
            guard let self else { return }
            let missing = await runBlocking { () -> [String] in
                ["gh", "git", "ssh"].filter { Shell.resolveExecutable($0) == nil }
            }
            if !missing.isEmpty {
                let list = missing.joined(separator: ", ")
                self.logStore.append("⚠ Missing required tools: \(list). Please install them and restart GitNest.")
            }
        }
    }

    /// Cancel timers and the in-flight auth process on app termination. Restore
    /// runs as the final `ghChain` job so it cannot race an in-flight repo list or
    /// account check that is still mid-switch.
    func prepareForTermination() async {
        repoManager.stopAllTimers()
        authProcessController.cancel()
        if let login = initialGhLogin, !login.isEmpty {
            await ghChain.serialized {
                _ = Shell.run(["gh", "auth", "switch", "-u", login], timeout: 5)
            }
        } else {
            await ghChain.awaitDrain()
        }
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
        // the app returns to the foreground. Skip when a project init/fork or
        // add-account flow is active — `canAutoRefresh` is already false in those
        // states and a foreground refresh shouldn't step on them either.
        Task { [weak self] in
            guard let self,
                  let account = self.accountManager.selectedAccount,
                  self.repoManager.canAutoRefresh else { return }
            if !self.repoManager.repos.isEmpty {
                await self.repoManager.refreshStatuses(for: account)
            }
            if self.repoManager.shouldAutoRefreshRepos(for: account.alias) {
                await self.repoManager.loadRepos(for: account, silent: true, userInitiated: false)
            }
        }
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
