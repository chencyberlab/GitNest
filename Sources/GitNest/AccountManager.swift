import SwiftUI
import Combine

@MainActor
final class AccountManager: ObservableObject {
    struct GhAuthIndicator: Sendable {
        let ok: Bool
        let text: String
    }

    private struct ReauthGhResult: Sendable {
        let login: ShellResult
        let switched: ShellResult?
    }

    @Published var accounts: [Account] = []
    @Published var selectedAccount: Account?
    @Published var sshGreetings: [String: String] = [:]   // alias -> "Hi X!"
    @Published var ghIndicators: [String: GhAuthIndicator] = [:] // alias -> gh auth status
    @Published var accountStatusChecksPending: Set<String> = []

    private let ghChain: GhChain
    private let logStore: LogStore
    private let authProcessController: AuthProcessController

    var accountStatusSessionID = UUID()
    var accountStatusLoadMode: AccountStatusLoadMode = .smart
    var currentAuthFlowCode: String?
    private var reauthClipboardWatcher: Task<Void, Never>?
    static let accountOrderDefaultsKey = "accountOrder"

    init(ghChain: GhChain, logStore: LogStore, authProcessController: AuthProcessController) {
        self.ghChain = ghChain
        self.logStore = logStore
        self.authProcessController = authProcessController
    }

    // MARK: Loading and selection

    func loadAccounts() {
        accounts = orderedAccounts(GitConfig.loadAccounts { [logStore] message in
            logStore.append("⚠ \(message)")
        })
        if let selectedAccount {
            self.selectedAccount = accounts.first { $0.alias == selectedAccount.alias }
        }
    }

    func refreshAll(statusMode: AccountStatusLoadMode? = nil, manual: Bool = false) {
        if let statusMode { accountStatusLoadMode = statusMode }
        accountStatusSessionID = UUID()
        accountStatusChecksPending.removeAll()
        loadAccounts()
        startAccountStatusChecks(mode: accountStatusLoadMode, manual: manual, force: true)
    }

    /// Account switch UX: update the selected account.
    func selectAccount(_ account: Account) {
        selectedAccount = account
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

    func configureAccountStatusLoadMode(_ mode: AccountStatusLoadMode) {
        accountStatusLoadMode = mode
    }

    // MARK: Account status

    /// On-demand: run `gh auth status` and append its full output to the Output
    /// log. Triggered by the button in the Output panel header — the per-account
    /// cards already show ready/login-required, so this is just for the raw detail.
    func logAuthStatus() async {
        logStore.append("$ gh auth status")
        let res = await runBlocking { GitHub.authStatus() }
        let text = (res.stdout + res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        logStore.append(text.isEmpty ? "gh: no output" : text)
    }

    func openGitHubProfile(_ account: Account) {
        guard let url = URL(string: "https://github.com/\(account.alias)") else { return }
        logStore.append("Opening github.com/\(account.alias) in browser…")
        NSWorkspace.shared.open(url)
    }

    func startAccountStatusChecks(mode: AccountStatusLoadMode, manual: Bool, force: Bool) {
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

    func selectedFirstAccounts() -> [Account] {
        guard let selectedAccount else { return [] }
        return [selectedAccount] + accounts.filter { $0.alias != selectedAccount.alias }
    }

    func refreshAccountStatusIfNeeded(for account: Account) {
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

    func beginAccountStatusChecks(_ requested: [Account], force: Bool) {
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

    func beginAccountStatusChecksSequentially(_ requested: [Account], force: Bool) {
        let session = accountStatusSessionID
        Task { [weak self] in
            var seen: Set<String> = []
            for account in requested where seen.insert(account.alias).inserted {
                guard let self else { return }
                await self.runAccountStatusCheckIfNeeded(account, session: session, force: force)
            }
        }
    }

    func loadAccountStatus(_ account: Account, session: UUID) async {
        let alias = account.alias
        // Clear the in-flight marker on every exit path. The condition is
        // deliberately looser than the early-return guards below — see
        // `clearAccountStatusPending`.
        defer { clearAccountStatusPending(alias, session: session) }
        let greeting = await runBlocking { GitHub.sshGreeting(host: account.sshHost) }
        guard isCurrentAccountStatusSession(session, alias: alias) else { return }
        sshGreetings[alias] = greeting

        let indicator = await ghChain.serialized { () -> GhAuthIndicator in
            // Snapshot whoever was active before this check so we can put gh back
            // exactly where it was. If the snapshot itself fails (transient network,
            // no active account), do NOT guess a restore target — guessing the
            // selected/first account would silently flip the user's active gh
            // identity to a different account than the one that was actually active.
            // Leaving gh where `ensureActiveAccount` left it (pointing at `alias`,
            // the account we just verified) is the lesser surprise; the next real
            // gh operation switches accounts as needed.
            let originalLogin = GitHub.currentActiveLoginForRestore()

            let check = GitHub.ensureActiveAccount(alias)

            if let originalLogin, !originalLogin.isEmpty {
                _ = Shell.run(["gh", "auth", "switch", "-u", originalLogin])
            }

            return GhAuthIndicator(ok: check.ok,
                                   text: check.ok ? "gh ready" : "gh login required")
        }
        guard isCurrentAccountStatusSession(session, alias: alias) else { return }
        ghIndicators[alias] = indicator
    }

    func isCurrentAccountStatusSession(_ session: UUID, alias: String) -> Bool {
        session == accountStatusSessionID
            && accounts.contains(where: { $0.alias == alias })
    }

    /// Drops `alias`'s in-flight marker when a `loadAccountStatus` check exits,
    /// but only while `session` is still the active batch.
    ///
    /// This is intentionally looser than `isCurrentAccountStatusSession`, the guard
    /// the in-body `await`s use: it checks the session ID but NOT that the account
    /// is still present. The divergence is the whole point. A check whose account
    /// was removed mid-flight (same session) early-returns without writing state,
    /// but it still inserted a marker in `accountStatusChecksPending` that only this
    /// task can remove — gating on account presence here would leak it. A newer
    /// batch (different session) bumps `accountStatusSessionID`, clears the set, and
    /// re-inserts its own markers, so the session check keeps us from deleting an
    /// entry we no longer own.
    func clearAccountStatusPending(_ alias: String, session: UUID) {
        guard session == accountStatusSessionID else { return }
        accountStatusChecksPending.remove(alias)
    }

    func runAccountStatusCheckIfNeeded(_ account: Account, session: UUID, force: Bool) async {
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

    // MARK: Readiness helpers

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

    // MARK: Re-authentication

    /// Starts `gh auth login --web` and then refreshes auth state shown in UI.
    func reauthenticateGh(for account: Account) async {
        logStore.append("Opening GitHub device login page for \(account.alias)…")
        if let deviceURL = URL(string: "https://github.com/login/device") {
            NSWorkspace.shared.open(deviceURL)
        }
        logStore.append("Starting gh auth login (web) for \(account.alias)…")
        currentAuthFlowCode = nil
        reauthClipboardWatcher?.cancel()
        let startingClipboardChangeCount = NSPasteboard.general.changeCount
        let clipboardWatcher = Task {
            if let code = await DeviceCodeWatcher.watchClipboard(
                startingChangeCount: startingClipboardChangeCount,
                maxIterations: 240
            ) {
                if currentAuthFlowCode != code {
                    logStore.append("One-time code copied to clipboard.")
                    currentAuthFlowCode = code
                }
            }
        }
        reauthClipboardWatcher = clipboardWatcher
        let authProcess = authProcessController.start()
        let result = await ghChain.serialized { () -> ReauthGhResult in
            let login = GitHub.authLoginWebWithClipboard(handle: authProcess)
            guard login.ok else { return ReauthGhResult(login: login, switched: nil) }
            return ReauthGhResult(login: login, switched: GitHub.ensureActiveAccount(account.alias))
        }
        authProcessController.finish(authProcess)
        clipboardWatcher.cancel()
        reauthClipboardWatcher = nil
        let login = result.login
        let authOutput = (login.stdout + login.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = DeviceCode.extract(fromGhOutput: authOutput) {
            if currentAuthFlowCode != code {
                logStore.append("One-time code copied to clipboard.")
                currentAuthFlowCode = code
            }
        }
        let safeAuthOutput = DeviceCode.redactedGhOutput(authOutput)
        if login.ok {
            // gh just refreshed its token in ~/.config/gh/hosts.yml — assert 0600 on it.
            await runBlocking { GitHub.hardenGhConfigPermissions() }
            logStore.append("✓ gh auth login completed.")
        } else {
            logStore.append("✗ gh auth login failed: \(safeAuthOutput.isEmpty ? "unknown error" : safeAuthOutput)")
            logStore.append("If prompted, paste the one-time code already copied to clipboard.")
            return
        }

        // Best effort: make the requested account active for subsequent operations.
        if result.switched?.ok == true {
            logStore.append("✓ Active gh account set to \(account.alias).")
        } else {
            let switchedOutput = (result.switched?.stdout ?? "") + (result.switched?.stderr ?? "")
            let out = switchedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            logStore.append("⚠ Could not switch to \(account.alias): \(out)")
        }
        beginAccountStatusChecks([account], force: true)
        await logAuthStatus()
        // The one-time device code is consumed once login completes; don't keep it
        // around past the flow that produced it.
        currentAuthFlowCode = nil
    }

}
