import SwiftUI
import AppKit

extension AppModel {
    /// On-demand: run `gh auth status` and append its full output to the Output
    /// log. Triggered by the button in the Output panel header — the per-account
    /// cards already show ready/login-required, so this is just for the raw detail.
    func logAuthStatus() async {
        appendLog("$ gh auth status")
        let res = await run { GitHub.authStatus() }
        let text = (res.stdout + res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        appendLog(text.isEmpty ? "gh: no output" : text)
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

}
