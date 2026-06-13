import SwiftUI
import AppKit

extension AppModel {
    // MARK: Per-repo actions

    struct RepoActionContext {
        let account: Account
        let path: String
        let repoIDs: Set<Repo.ID>
    }

    func beginRepoAction(_ repo: Repo, in explicitAccount: Account? = nil) -> RepoActionContext? {
        guard let account = explicitAccount ?? selectedAccount else { return nil }
        if !accounts.isEmpty && !accounts.contains(where: { $0.alias == account.alias }) {
            appendLog("✗ Cannot run action for \(repo.nameWithOwner): account \(account.alias) is no longer configured.")
            return nil
        }
        let path = localPath(repo, in: account)
        let sourceRepos = selectedAccount?.alias == account.alias ? repos : (repoCache[account.alias] ?? [])
        var ids = Set(sourceRepos.filter { localPath($0, in: account) == path }.map(\.id))
        ids.insert(repo.id)
        guard busyRepos.isDisjoint(with: ids),
              busyRepoPaths.insert(path).inserted else { return nil }
        busyRepos.formUnion(ids)
        return RepoActionContext(account: account, path: path, repoIDs: ids)
    }

    func finishRepoAction(_ context: RepoActionContext) {
        busyRepos.subtract(context.repoIDs)
        busyRepoPaths.remove(context.path)
    }

    func clone(_ repo: Repo, in account: Account? = nil) async {
        guard let context = beginRepoAction(repo, in: account) else { return }
        defer { finishRepoAction(context) }
        let account = context.account
        let alias = account.alias
        let dest = context.path
        // Snapshot this account's sets now, while it's the selected one, so an
        // account switch during the await can't land its result in another
        // account's visible UI (or write that account's dict into this cache).
        var cloned = clonedRepos
        var conflicts = repoFolderConflicts
        let state = await run { Self.localFolderState(for: repo, path: dest) }
        switch state {
        case .cloned:
            cloned.insert(repo.id)
            conflicts.removeValue(forKey: repo.id)
            commitCloneState(cloned, conflicts, for: alias)
            appendLog("\(repo.nameWithOwner) is already cloned at \(dest).")
            await refreshStatuses(for: account, refreshRemote: true)
            return
        case .occupied(let conflict):
            conflicts[repo.id] = conflict
            commitCloneState(cloned, conflicts, for: alias)
            appendLog("✗ Cannot clone \(repo.nameWithOwner): \(conflict.message)")
            return
        case .absent:
            break
        }

        appendLog("Cloning \(repo.nameWithOwner) → \(account.folder)…")
        let folder = account.folder
        let res = await run { GitHub.clone(repo: repo, into: folder) }
        report(res, ok: "cloned \(repo.name)")
        await refreshClonedStatus(for: account)
        await refreshStatuses(for: account, refreshRemote: true)
    }

    func pull(_ repo: Repo, in account: Account? = nil) async {
        guard let context = beginRepoAction(repo, in: account) else { return }
        defer { finishRepoAction(context) }
        let account = context.account
        let path = context.path

        let dirty = await run { GitHub.hasUncommittedChanges(at: path) }
        if dirty {
            appendLog("⚠ Pull blocked for \(repo.name): uncommitted or untracked changes.")
            pullWarning = PullWarning(
                repoName: repo.name,
                message: """
                \(repo.name) has uncommitted or untracked changes.

                Pulling now could overwrite or merge into your local work. Commit, stash, or discard your changes before pulling.
                """
            )
            await refreshStatuses(for: account)
            return
        }

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

    func push(_ repo: Repo, in account: Account? = nil) async {
        guard let context = beginRepoAction(repo, in: account) else { return }
        defer { finishRepoAction(context) }
        let account = context.account
        let path = context.path
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
        let startingClipboardChangeCount = NSPasteboard.general.changeCount
        let clipboardWatcher = Task { await watchClipboardForDeviceCode(after: startingClipboardChangeCount) }
        let authProcess = startAuthProcess()
        let login = await run { GitHub.authLoginWebWithClipboard(handle: authProcess) }
        finishAuthProcess(authProcess)
        clipboardWatcher.cancel()
        let authOutput = (login.stdout + login.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if let code = DeviceCode.extract(fromGhOutput: authOutput) {
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

    func openLocalFolder(_ repo: Repo, in explicitAccount: Account? = nil) {
        guard let account = explicitAccount ?? selectedAccount else { return }
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
    func openInEditor(_ repo: Repo,
                      in explicitAccount: Account? = nil,
                      editor: PreferredEditor,
                      customAppName: String) async {
        guard editor != .none, let account = explicitAccount ?? selectedAccount else { return }
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
    func openInTerminal(_ repo: Repo,
                        in explicitAccount: Account? = nil,
                        terminal: PreferredTerminal,
                        customAppName: String) async {
        guard terminal != .none, let account = explicitAccount ?? selectedAccount else { return }
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
    func changedFiles(for repo: Repo,
                      in explicitAccount: Account? = nil) async -> Result<[GitFileChange], CommandError> {
        guard let account = explicitAccount ?? selectedAccount else {
            return .failure(CommandError(message: "No account selected."))
        }
        let path = localPath(repo, in: account)
        let gitDir = (path as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else {
            return .failure(CommandError(message: "This repository isn't cloned locally."))
        }
        return await run { GitHub.changedFiles(at: path) }
    }

    /// Move the local clone to Trash (does NOT touch the GitHub repo).
    func deleteLocalFolder(_ repo: Repo, in account: Account? = nil) async {
        guard let context = beginRepoAction(repo, in: account) else { return }
        defer { finishRepoAction(context) }
        let account = context.account
        let path = context.path
        appendLog("Moving \(repo.name) folder to Trash…")
        let res = await run { FileOps.moveToTrash(path) }
        report(res, ok: "moved \(repo.name) to Trash")
        await refreshClonedStatus(for: account)
        await refreshStatuses(for: account)
    }

    func commit(_ repo: Repo, message: String, in account: Account? = nil) async {
        guard !message.trimmingCharacters(in: .whitespaces).isEmpty,
              let context = beginRepoAction(repo, in: account) else { return }
        defer { finishRepoAction(context) }
        let account = context.account
        let path = context.path
        appendLog("Committing \(repo.name): “\(message)”…")
        let res = await run { GitHub.commitAll(at: path, message: message) }
        report(res, ok: "committed \(repo.name)")
        await refreshStatuses(for: account)
    }

    func initProject(_ plan: ProjectInitPlan,
                     visibility: RepoVisibilityChoice,
                     moveOriginalToTrash: Bool = false) async -> Bool {
        isInitializingProject = true
        defer { isInitializingProject = false }
        appendLog("Initializing \(plan.repoName) for \(plan.account.alias)…")
        let res = await ghSerializedPreservingActiveAccount { GitHub.initAndPushProject(plan, visibility: visibility) }
        report(res, ok: "initialized and pushed \(plan.account.alias)/\(plan.repoName)")
        if res.ok, plan.willCopy, moveOriginalToTrash {
            appendLog("Moving original folder to Trash…")
            let trash = await run { FileOps.moveToTrash(plan.sourcePath) }
            report(trash, ok: "moved original \(plan.sourceName) to Trash")
        }
        await refreshClonedStatus(for: plan.account)
        await refreshStatuses(for: plan.account, refreshRemote: true)
        return res.ok
    }

    /// Fork a GitHub repository into the selected account and clone it into the
    /// account's folder. Returns `true` when both fork and clone succeeded.
    func forkProject(source: String, account: Account) async -> Bool {
        guard let ref = RepoReference.parse(source) else {
            appendLog("✗ Invalid GitHub project address: \(source)")
            return false
        }

        isForkingProject = true
        defer { isForkingProject = false }
        appendLog("Forking \(ref.nameWithOwner) into \(account.alias)'s account…")

        let forkResult = await ghSerializedPreservingActiveAccount { GitHub.fork(source: ref, intoAccount: account.alias) }
        guard case .success(let repo) = forkResult else {
            if case .failure(let error) = forkResult {
                appendLog("✗ Fork failed: \(error.message)")
            } else {
                appendLog("✗ Fork failed.")
            }
            return false
        }

        appendLog("✓ Fork ready: \(repo.nameWithOwner). Cloning into \(account.folder)…")
        let cloneRes = await run { GitHub.clone(repo: repo, into: account.folder) }
        report(cloneRes, ok: "cloned \(repo.name)")

        guard cloneRes.ok else {
            await refreshClonedStatus(for: account)
            await refreshStatuses(for: account, refreshRemote: true)
            return false
        }

        let dest = localPath(repo, in: account)
        let upstream = await run { GitHub.setUpstream(source: ref, at: dest) }
        let upstreamText = (upstream.stdout + upstream.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if upstream.ok {
            appendLog("✓ added upstream \(ref.nameWithOwner)" + (upstreamText.isEmpty ? "" : "\n\(upstreamText)"))
        } else {
            appendLog("⚠ Cloned, but could not add upstream: \(upstreamText.isEmpty ? "unknown error" : upstreamText)")
        }

        await refreshClonedStatus(for: account)
        await refreshStatuses(for: account, refreshRemote: true)

        // Also refresh the repo list so the newly forked repo appears as a row.
        await loadRepos(for: account, silent: true, userInitiated: false)

        return true
    }

}
