import SwiftUI
import AppKit

@MainActor
final class SetupCoordinator: ObservableObject {
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
    /// Whether a freshly *created* key was encrypted (passphrase seeded into the
    /// login Keychain). Only meaningful when `addAccountKeyCreated`; a reused key
    /// leaves it `true` since its state isn't touched. False means the key was left
    /// unencrypted because the Keychain/ssh-agent couldn't be reached — surfaced as
    /// a warning on the SSH-key step, not just a log line.
    @Published var addAccountKeyHardened = true
    @Published var addAccountVerification: AccountSetup.Verification?

    private let ghChain: GhChain
    private let logStore: LogStore
    private let accountManager: AccountManager
    private let authProcessController: AuthProcessController

    var addAccountSessionID = UUID()
    private var addAccountClipboardWatcher: Task<Void, Never>?

    /// Alias for the in-progress account (GitHub login, lowercased).
    var addAccountAlias: String? { addAccountIdentity?.alias }

    /// Existing accounts, exposed so the add-account sheet can check for folder overlaps.
    var accounts: [Account] { accountManager.accounts }

    /// Two-way binding for the add-account sheet: reads the source of truth and
    /// calls `cancelAddAccount()` when the sheet is dismissed, so the in-flight
    /// `gh auth login` poll is killed and the chain is freed. Lives on the
    /// coordinator (not AppModel) so views can bind directly to the source.
    var addAccountActiveBinding: Binding<Bool> {
        Binding(
            get: { self.addAccountActive },
            set: { isPresented in
                if isPresented {
                    self.addAccountActive = true
                } else if self.addAccountActive {
                    self.cancelAddAccount()
                }
            }
        )
    }

    init(ghChain: GhChain,
         logStore: LogStore,
         accountManager: AccountManager,
         authProcessController: AuthProcessController) {
        self.ghChain = ghChain
        self.logStore = logStore
        self.accountManager = accountManager
        self.authProcessController = authProcessController
    }

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
        addAccountKeyHardened = true
        addAccountVerification = nil
        addAccountActive = true
    }

    func cancelAddAccount() {
        // If verification already ran, the config was written — refresh so the new
        // account's cards/chips populate, just like the Done path (minus the select).
        let wroteConfig = addAccountVerification != nil
        addAccountClipboardWatcher?.cancel()
        addAccountClipboardWatcher = nil
        // Kill any in-flight `gh auth login` poll so it doesn't keep the serialized
        // gh chain busy (blocking repo refreshes/account checks) for up to ~10 min.
        authProcessController.cancel()
        addAccountSessionID = UUID()
        addAccountActive = false
        addAccountBusy = false
        if wroteConfig { accountManager.refreshAll() }
    }

    func isCurrentAddAccountSession(_ session: UUID) -> Bool {
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
        logStore.append("Add account: starting GitHub sign-in…")
        if let url = URL(string: "https://github.com/login/device") {
            NSWorkspace.shared.open(url)
        }
        let startingClipboardChangeCount = NSPasteboard.general.changeCount
        addAccountClipboardWatcher?.cancel()
        // [weak self]: the clipboard poll can run up to ~120s and SetupCoordinator
        // owns the handle — don't let the Task strong-capture it. The session guard
        // below still drops a result from a superseded wizard.
        let watcher = Task { [weak self] in
            let code = await DeviceCodeWatcher.watchClipboard(
                startingChangeCount: startingClipboardChangeCount,
                maxIterations: 240
            )
            guard let self, self.isCurrentAddAccountSession(session) else { return }
            if let code { self.addAccountDeviceCode = code }
        }
        addAccountClipboardWatcher = watcher
        let authProcess = authProcessController.start()
        let result = await ghChain.serialized { () -> AddAccountLoginResult in
            let login = GitHub.authLoginWebWithClipboard(handle: authProcess)
            guard login.ok else { return AddAccountLoginResult(login: login, identity: nil) }
            return AddAccountLoginResult(login: login, identity: AccountSetup.currentIdentity())
        }
        authProcessController.finish(authProcess)
        watcher.cancel()
        addAccountClipboardWatcher = nil
        guard isCurrentAddAccountSession(session) else { return }
        let out = (result.login.stdout + result.login.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = DeviceCode.extract(fromGhOutput: out) { addAccountDeviceCode = code }
        let safeOut = DeviceCode.redactedGhOutput(out)
        guard result.login.ok else {
            setAddAccountError("Sign-in failed: \(safeOut.isEmpty ? "unknown error" : safeOut)")
            addAccountBusy = false
            return
        }
        // gh just wrote a fresh token to ~/.config/gh/hosts.yml — assert 0600 on it.
        await runBlocking { GitHub.hardenGhConfigPermissions() }
        guard let identity = result.identity else {
            setAddAccountError("Could not read account after sign-in.")
            addAccountBusy = false
            return
        }
        switch identity {
        case .success(let id):
            if accountManager.accounts.contains(where: { $0.alias.caseInsensitiveCompare(id.alias) == .orderedSame }) {
                setAddAccountError("\(id.login) is already set up in this app.")
                addAccountBusy = false
                return
            }
            addAccountIdentity = id
            addAccountEmail = id.noreplyEmail
            logStore.append("Add account: signed in as \(id.login).")
            addAccountStep = .folder
        case .failure(let e):
            setAddAccountError("Could not read account: \(e.displayMessage)")
        }
        addAccountBusy = false
    }

    func setAddAccountFolder(_ path: String?) { addAccountFolder = path }

    func setAddAccountError(_ message: String) {
        addAccountError = Redaction.scrub(message)
    }

    /// Step 2 → 3 — generate (or reuse) the dedicated SSH key, then show its pubkey.
    func addAccountGenerateKey() async {
        guard let id = addAccountIdentity else { return }
        let session = addAccountSessionID
        addAccountBusy = true
        addAccountError = nil
        let alias = id.alias
        let comment = addAccountEmail.isEmpty ? alias : addAccountEmail
        let result = await runBlocking { AccountSetup.ensureKey(alias: alias, comment: comment) }
        guard isCurrentAddAccountSession(session) else { return }
        switch result {
        case .success(let r):
            addAccountPublicKey = r.publicKey
            addAccountKeyCreated = r.created
            // `hardened` is only meaningful for a newly created key; a reused key's
            // encryption state is left untouched, so treat it as hardened (no warning).
            addAccountKeyHardened = r.created ? r.hardened : true
            if r.created {
                logStore.append(r.hardened
                              ? "Add account: generated SSH key id_\(alias) (encrypted; passphrase saved to your login Keychain)."
                              : "Add account: generated SSH key id_\(alias) (unencrypted — couldn't reach ssh-agent/Keychain to store a passphrase, so it's protected by file permissions only).")
            } else {
                logStore.append("Add account: reusing existing SSH key id_\(alias).")
            }
            addAccountStep = .sshKey
        case .failure(let e):
            setAddAccountError("SSH key error: \(e.displayMessage)")
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
        logStore.append("Add account: writing config for \(alias) (backups first)…")

        let sshWrite = await runBlocking { AccountSetup.ensureSSHConfig(alias: alias) }
        guard isCurrentAddAccountSession(session) else { return }
        switch sshWrite {
        case .success(let result):
            if let backup = result.backupPath { logStore.append("Add account: backed up ~/.ssh/config -> \(backup).") }
            if result.wroteBlock { logStore.append("Add account: added ~/.ssh/config host github-\(alias).") }
        case .failure(let e):
            setAddAccountError(e.displayMessage); addAccountBusy = false; return
        }

        // Advisory (non-blocking): an earlier `Host *`/`Host github-*` block with its
        // own IdentityFile would also be offered for this host under IdentitiesOnly,
        // which can let a different key authenticate the wrong account. The greeting
        // check below still fails closed if that happens; this just names the cause.
        let foreignKeys = await runBlocking { () -> [String] in
            let configText = (try? String(contentsOfFile: AccountSetup.sshConfigPath(), encoding: .utf8)) ?? ""
            return AccountSetup.foreignIdentityFiles(host: "github-\(alias)",
                                                     expectedKeyPath: AccountSetup.keyPath(alias: alias),
                                                     in: configText)
        }
        guard isCurrentAddAccountSession(session) else { return }
        if !foreignKeys.isEmpty {
            logStore.append("⚠ Add account: another ~/.ssh/config block also offers \(foreignKeys.joined(separator: ", ")) for github-\(alias). Under IdentitiesOnly that can let the wrong key authenticate — if verification shows an unexpected account, scope that block (or move it below the github-\(alias) block).")
        }

        let name = id.displayName
        // Fall back to the no-reply address if the field was cleared, so the account
        // never gets an empty user.email (which breaks commits in its repos). Mirrors
        // the name fallback in id.displayName.
        let trimmedEmail = addAccountEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = trimmedEmail.isEmpty ? id.noreplyEmail : trimmedEmail
        let existingFolders = accountManager.accounts.map(\.folder)
        let write = await runBlocking {
            AccountSetup.writeGitConfig(alias: alias,
                                        name: name,
                                        email: email,
                                        folder: folder,
                                        existingAccountFolders: existingFolders)
        }
        guard isCurrentAddAccountSession(session) else { return }
        if case .failure(let e) = write {
            setAddAccountError(e.displayMessage); addAccountBusy = false; return
        }
        if case .success(let result) = write {
            if let backup = result.accountGitconfigBackupPath { logStore.append("Add account: backed up account gitconfig -> \(backup).") }
            if let backup = result.globalGitconfigBackupPath { logStore.append("Add account: backed up ~/.gitconfig -> \(backup).") }
        }
        logStore.append("Add account: wrote gitconfig + includeIf, created \(folder).")

        await addAccountReverify()
        accountManager.accounts = accountManager.orderedAccounts(GitConfig.loadAccounts())
        addAccountBusy = false
    }

    /// Re-run SSH/gh verification (handy right after pasting the key, which can take
    /// a moment to propagate on GitHub's side).
    func addAccountReverify() async {
        guard let alias = addAccountAlias else { return }
        let session = addAccountSessionID
        // verify() switches the active gh account to `alias`; preserve+restore the
        // previously active account around it so the mid-wizard Re-verify button
        // doesn't leave global gh state pointing at this half-configured account.
        let result = await ghChain.serializedPreservingActiveAccount { AccountSetup.verify(alias: alias) }
        guard isCurrentAddAccountSession(session) else { return }
        addAccountVerification = result
        let sshText = result.sshOK ? "OK" : (result.sshLogin.map { "as \($0), expected \(alias)" } ?? "not ready")
        let ghText = result.ghOK ? "OK" : (result.ghLogin.map { "as \($0), expected \(alias)" } ?? "unknown")
        logStore.append("Add account: verify — SSH \(sshText), gh \(ghText).")
        if let restoreWarning = result.restoreWarning {
            logStore.append("⚠ Add account: \(restoreWarning)")
        }
    }

    /// Close the wizard, refresh everything, and select the new account.
    func completeAddAccount() {
        let newAlias = addAccountAlias
        addAccountSessionID = UUID()
        addAccountActive = false
        accountManager.refreshAll()
        if let newAlias, let acct = accountManager.accounts.first(where: { $0.alias.caseInsensitiveCompare(newAlias) == .orderedSame }) {
            accountManager.selectAccount(acct)
        }
    }

}
