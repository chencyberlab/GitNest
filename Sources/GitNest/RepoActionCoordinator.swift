import SwiftUI
import AppKit

@MainActor
final class RepoActionCoordinator: ObservableObject {
    struct RepoActionContext {
        let account: Account
        let path: String
        let repoIDs: Set<Repo.ID>
    }

    /// Repos with a mutating local action in flight, so the row can disable its
    /// buttons and a double-click can't run two operations on the same repo. Rows
    /// that share a local folder are marked busy together; `busyRepoPaths` is the
    /// backend guard for rows that appear after a refresh while work is in flight.
    @Published var busyRepos: Set<Repo.ID> = []
    var busyRepoPaths: Set<String> = []

    private let repoManager: RepoManager
    private let logStore: LogStore
    private let alertStore: AlertStore
    private let accountManager: AccountManager

    init(repoManager: RepoManager,
         logStore: LogStore,
         alertStore: AlertStore,
         accountManager: AccountManager) {
        self.repoManager = repoManager
        self.logStore = logStore
        self.alertStore = alertStore
        self.accountManager = accountManager
    }

    func isRepoActionBusy(_ repo: Repo) -> Bool {
        guard let account = accountManager.selectedAccount else {
            return busyRepos.contains(repo.id)
        }
        return busyRepos.contains(repo.id) || busyRepoPaths.contains(repoManager.localPath(repo, in: account))
    }

    func beginRepoAction(_ repo: Repo, in explicitAccount: Account? = nil) -> RepoActionContext? {
        guard let account = explicitAccount ?? accountManager.selectedAccount else { return nil }
        if !accountManager.accounts.isEmpty && !accountManager.accounts.contains(where: { $0.alias == account.alias }) {
            logStore.append("✗ Cannot run action for \(repo.nameWithOwner): account \(account.alias) is no longer configured.")
            return nil
        }
        let path = repoManager.localPath(repo, in: account)
        let sourceRepos = accountManager.selectedAccount?.alias == account.alias
            ? repoManager.repos
            : (repoManager.repoCache[account.alias] ?? [])
        var ids = Set(sourceRepos.filter { repoManager.localPath($0, in: account) == path }.map(\.id))
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
        // Snapshot the target account's state, whether or not it is visible.
        // Explicit-account actions can complete after the user switches accounts.
        var (cloned, conflicts) = repoManager.cloneState(for: alias)
        let state = await runBlocking {
            AppModel.localFolderState(for: repo, path: dest, expectedSSHHost: account.sshHost)
        }
        switch state {
        case .cloned:
            cloned.insert(repo.id)
            conflicts.removeValue(forKey: repo.id)
            repoManager.commitCloneState(cloned, conflicts, for: alias)
            logStore.append("\(repo.nameWithOwner) is already cloned at \(dest).")
            await repoManager.refreshStatuses(for: account, refreshRemote: true)
            return
        case .occupied(let conflict):
            conflicts[repo.id] = conflict
            repoManager.commitCloneState(cloned, conflicts, for: alias)
            logStore.append("✗ Cannot clone \(repo.nameWithOwner): \(conflict.message)")
            return
        case .absent:
            break
        }

        logStore.append("Cloning \(repo.nameWithOwner) → \(account.folder)…")
        let folder = account.folder
        let res = await runBlocking { GitHub.clone(repo: repo, into: folder) }
        logStore.report(res, ok: "cloned \(repo.name)")
        await repoManager.refreshClonedStatus(for: account)
        await repoManager.refreshStatuses(for: account, refreshRemote: true)
    }

    func pull(_ repo: Repo, in account: Account? = nil) async {
        guard let context = beginRepoAction(repo, in: account) else { return }
        defer { finishRepoAction(context) }
        let account = context.account
        let path = context.path

        let dirty = await runBlocking { GitHub.hasUncommittedChanges(at: path) }
        if dirty {
            logStore.append("⚠ Pull blocked for \(repo.name): uncommitted or untracked changes.")
            alertStore.showPullWarning(AlertStore.PullWarning(
                repoName: repo.name,
                message: """
                \(repo.name) has uncommitted or untracked changes.

                Pulling now could overwrite or merge into your local work. Commit, stash, or discard your changes before pulling.
                """
            ))
            await repoManager.refreshStatuses(for: account)
            return
        }

        logStore.append("Pulling \(repo.name)…")
        let res = await runBlocking { GitHub.pull(at: path) }
        logStore.report(res, ok: "pulled \(repo.name)")
        if !res.ok {
            alertStore.showPullWarning(AlertStore.PullWarning(
                repoName: repo.name,
                message: AlertStore.PullWarning.message(repoName: repo.name, gitOutput: res.stdout + res.stderr)
            ))
        }
        await repoManager.refreshStatuses(for: account, refreshRemote: true)
    }

    func push(_ repo: Repo, in account: Account? = nil) async {
        guard let context = beginRepoAction(repo, in: account) else { return }
        defer { finishRepoAction(context) }
        let account = context.account
        let path = context.path
        logStore.append("Pushing \(repo.name)…")
        let res = await runBlocking { GitHub.push(at: path) }
        logStore.report(res, ok: "pushed \(repo.name)")
        await repoManager.refreshStatuses(for: account, refreshRemote: true)
    }

    func openGitHubRepo(_ repo: Repo) {
        guard let url = URL(string: repo.url) else { return }
        logStore.append("Opening \(repo.nameWithOwner) on GitHub in browser…")
        NSWorkspace.shared.open(url)
    }

    func openLocalFolder(_ repo: Repo, in explicitAccount: Account? = nil) {
        guard let account = explicitAccount ?? accountManager.selectedAccount else { return }
        let path = repoManager.localPath(repo, in: account)
        guard FileManager.default.fileExists(atPath: path) else {
            logStore.append("✗ folder not found: \(path)")
            return
        }
        logStore.append("Opening \(repo.name) folder…")
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Open a cloned repo's folder in the user's chosen GUI editor. Runs `open -a`
    /// off the main actor and logs a friendly message if the editor can't open.
    func openInEditor(_ repo: Repo,
                      in explicitAccount: Account? = nil,
                      editor: PreferredEditor,
                      customAppName: String) async {
        guard editor != .none, let account = explicitAccount ?? accountManager.selectedAccount else { return }
        let path = repoManager.localPath(repo, in: account)
        guard FileManager.default.fileExists(atPath: path) else {
            logStore.append("✗ folder not found: \(path)")
            return
        }
        let result: Result<String, EditorOpenError> = await runBlocking {
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
            logStore.append("Opening \(repo.name) in \(name)…")
        case .failure(let error):
            logStore.append("✗ \(EditorLauncher.message(for: error))")
        }
    }

    /// Open a cloned repo's folder in the user's chosen GUI terminal. Runs `open -a`
    /// off the main actor and logs a friendly message if the terminal can't open.
    func openInTerminal(_ repo: Repo,
                        in explicitAccount: Account? = nil,
                        terminal: PreferredTerminal,
                        customAppName: String) async {
        guard terminal != .none, let account = explicitAccount ?? accountManager.selectedAccount else { return }
        let path = repoManager.localPath(repo, in: account)
        guard FileManager.default.fileExists(atPath: path) else {
            logStore.append("✗ folder not found: \(path)")
            return
        }
        let result: Result<String, TerminalOpenError> = await runBlocking {
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
            logStore.append("Opening \(repo.name) in \(name)…")
        case .failure(let error):
            logStore.append("✗ \(TerminalLauncher.message(for: error))")
        }
    }

    /// Load the detailed changed-file list for a repo on demand (for the summary
    /// popover). Kept out of the interval scan, which only tracks counts. Reports a
    /// friendly error when the repo isn't cloned or git fails.
    func changedFiles(for repo: Repo,
                      in explicitAccount: Account? = nil) async -> Result<[GitFileChange], CommandError> {
        guard let account = explicitAccount ?? accountManager.selectedAccount else {
            return .failure(CommandError(message: "No account selected."))
        }
        let path = repoManager.localPath(repo, in: account)
        let gitDir = (path as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else {
            return .failure(CommandError(message: "This repository isn't cloned locally."))
        }
        return await runBlocking { GitHub.changedFiles(at: path) }
    }

    /// Move the local clone to Trash (does NOT touch the GitHub repo).
    func deleteLocalFolder(_ repo: Repo, in account: Account? = nil) async {
        guard let context = beginRepoAction(repo, in: account) else { return }
        defer { finishRepoAction(context) }
        let account = context.account
        let path = context.path
        logStore.append("Moving \(repo.name) folder to Trash…")
        let res = await runBlocking { FileOps.moveToTrash(path) }
        logStore.report(res, ok: "moved \(repo.name) to Trash")
        await repoManager.refreshClonedStatus(for: account)
        await repoManager.refreshStatuses(for: account)
    }

    func commit(_ repo: Repo, message: String, in account: Account? = nil) async {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let context = beginRepoAction(repo, in: account) else { return }
        defer { finishRepoAction(context) }
        let account = context.account
        let path = context.path
        logStore.append("Committing \(repo.name): “\(message)”…")
        let res = await runBlocking { GitHub.commitAll(at: path, message: message) }
        logStore.report(res, ok: "committed \(repo.name)")
        await repoManager.refreshStatuses(for: account)
    }
}
