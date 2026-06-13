import SwiftUI
import Combine

@MainActor
final class AccountManager: ObservableObject {
    struct GhAuthIndicator: Sendable {
        let ok: Bool
        let text: String
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
    static let accountOrderDefaultsKey = "accountOrder"

    init(ghChain: GhChain, logStore: LogStore, authProcessController: AuthProcessController) {
        self.ghChain = ghChain
        self.logStore = logStore
        self.authProcessController = authProcessController
    }

    // MARK: Loading and selection

    func loadAccounts() {
        accounts = orderedAccounts(GitConfig.loadAccounts())
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
        let greeting = await runBlocking { GitHub.sshGreeting(host: account.sshHost) }
        guard isCurrentAccountStatusSession(session, alias: alias) else { return }
        sshGreetings[alias] = greeting

        let fallback = selectedAccount?.alias ?? accounts.first?.alias
        let indicator = await ghChain.serialized { () -> GhAuthIndicator in
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

    func isCurrentAccountStatusSession(_ session: UUID, alias: String) -> Bool {
        session == accountStatusSessionID
            && accounts.contains(where: { $0.alias == alias })
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
        let startingClipboardChangeCount = NSPasteboard.general.changeCount
        let clipboardWatcher = Task { await watchClipboardForDeviceCode(after: startingClipboardChangeCount) }
        let authProcess = authProcessController.start()
        let login = await runBlocking { GitHub.authLoginWebWithClipboard(handle: authProcess) }
        authProcessController.finish(authProcess)
        clipboardWatcher.cancel()
        let authOutput = (login.stdout + login.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = DeviceCode.extract(fromGhOutput: authOutput) {
            if currentAuthFlowCode != code {
                logStore.append("One-time code: \(code) (also copied to clipboard)")
                currentAuthFlowCode = code
            }
        }
        if login.ok {
            logStore.append("✓ gh auth login completed.")
        } else {
            logStore.append("✗ gh auth login failed: \(authOutput.isEmpty ? "unknown error" : authOutput)")
            logStore.append("If prompted, paste the one-time code already copied to clipboard.")
            return
        }

        // Best effort: make the requested account active for subsequent operations.
        let switched = await ghChain.serialized { GitHub.ensureActiveAccount(account.alias) }
        if switched.ok {
            logStore.append("✓ Active gh account set to \(account.alias).")
        } else {
            let out = (switched.stdout + switched.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            logStore.append("⚠ Could not switch to \(account.alias): \(out)")
        }
        beginAccountStatusChecks([account], force: true)
        await logAuthStatus()
    }

    /// Watch the clipboard for a GitHub device code while an auth flow runs.
    /// Only reads the pasteboard when its `changeCount` advances, so it does not
    /// repeatedly trigger macOS clipboard-privacy alerts.
    private func watchClipboardForDeviceCode(after startingChangeCount: Int) async {
        var lastChangeCount = startingChangeCount
        for _ in 0..<120 { // up to ~60 seconds
            if Task.isCancelled { return }
            let current = NSPasteboard.general.changeCount
            if current != lastChangeCount {
                lastChangeCount = current
                if let clip = NSPasteboard.general.string(forType: .string),
                   let code = DeviceCode.extract(fromClipboard: clip),
                   currentAuthFlowCode != code {
                    logStore.append("One-time code: \(code) (also copied to clipboard)")
                    currentAuthFlowCode = code
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
