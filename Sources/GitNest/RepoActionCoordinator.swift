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
              busyRepoPaths.insert(path).inserted else {
            logStore.append("⚠ \(repo.name): another action is already running — skipped.")
            return nil
        }
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

    /// Download remote changes without merging. Safe even with uncommitted work,
    /// so (unlike pull) there's no dirty-tree guard. Refreshes status with a live
    /// remote check afterward so ahead/behind and the green "up to date" badge
    /// reflect what just arrived.
    func fetch(_ repo: Repo, in account: Account? = nil) async {
        guard let context = beginRepoAction(repo, in: account) else { return }
        defer { finishRepoAction(context) }
        let account = context.account
        let path = context.path
        logStore.append("Fetching \(repo.name)…")
        let res = await runBlocking { GitHub.fetch(at: path) }
        logStore.report(res, ok: "fetched \(repo.name)")
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

    /// Load recent commits for the history popover. Read-only and network-free —
    /// mirrors `changedFiles`. Reports a friendly error when the repo isn't cloned.
    func recentCommits(for repo: Repo,
                       in explicitAccount: Account? = nil) async -> Result<[GitCommit], CommandError> {
        guard let account = explicitAccount ?? accountManager.selectedAccount else {
            return .failure(CommandError(message: "No account selected."))
        }
        let path = repoManager.localPath(repo, in: account)
        let gitDir = (path as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else {
            return .failure(CommandError(message: "This repository isn't cloned locally."))
        }
        return await runBlocking { GitHub.recentCommits(at: path) }
    }

    /// Load commits the current branch is behind its upstream by, for the incoming-
    /// commits popover. Read-only and network-free — mirrors `recentCommits`.
    /// Reflects the last fetch, so it pairs with the Fetch action in the row menu.
    func incomingCommits(for repo: Repo,
                         in explicitAccount: Account? = nil) async -> Result<[GitCommit], CommandError> {
        guard let account = explicitAccount ?? accountManager.selectedAccount else {
            return .failure(CommandError(message: "No account selected."))
        }
        let path = repoManager.localPath(repo, in: account)
        let gitDir = (path as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else {
            return .failure(CommandError(message: "This repository isn't cloned locally."))
        }
        return await runBlocking { GitHub.incomingCommits(at: path) }
    }

    // MARK: GitHub navigation & clipboard (non-mutating)

    /// Open the repo's pull-requests page on GitHub.
    func openPullRequests(_ repo: Repo) { openGitHubPage(repo, path: "pulls", label: "pull requests") }

    /// Open the repo's issues page on GitHub.
    func openIssues(_ repo: Repo) { openGitHubPage(repo, path: "issues", label: "issues") }

    private func openGitHubPage(_ repo: Repo, path: String, label: String) {
        guard let url = URL(string: "https://github.com/\(repo.nameWithOwner)/\(path)") else { return }
        logStore.append("Opening \(label) for \(repo.nameWithOwner) on GitHub…")
        NSWorkspace.shared.open(url)
    }

    /// Copy the HTTPS clone URL (e.g. https://github.com/owner/repo.git).
    func copyHTTPSURL(_ repo: Repo) {
        copyToClipboard("https://github.com/\(repo.nameWithOwner).git", describing: "HTTPS URL for \(repo.name)")
    }

    /// Copy the standard SSH clone URL (git@github.com:owner/repo.git). The plain
    /// github.com host is used rather than the per-account alias so the copied URL is
    /// portable to other machines/CI; local clones still route via the alias rewrite.
    func copySSHURL(_ repo: Repo) {
        copyToClipboard("git@github.com:\(repo.nameWithOwner).git", describing: "SSH URL for \(repo.name)")
    }

    /// Copy a ready-to-run `gh repo clone` command.
    func copyCloneCommand(_ repo: Repo) {
        copyToClipboard("gh repo clone \(repo.nameWithOwner)", describing: "clone command for \(repo.name)")
    }

    private func copyToClipboard(_ value: String, describing label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        logStore.append("Copied \(label) to clipboard.")
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

    // MARK: Stash (local parking; never touches GitHub)

    /// Read-only: all stash entries for the stash popover. Mirrors `recentCommits` —
    /// returns a friendly error when the repo isn't cloned or git fails.
    func stashList(for repo: Repo, in explicitAccount: Account? = nil) async -> Result<[GitStashEntry], CommandError> {
        guard let account = explicitAccount ?? accountManager.selectedAccount else {
            return .failure(CommandError(message: "No account selected."))
        }
        let path = repoManager.localPath(repo, in: account)
        let gitDir = (path as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else {
            return .failure(CommandError(message: "This repository isn't cloned locally."))
        }
        return await runBlocking { GitHub.stashList(at: path) }
    }

    /// Live working-tree dirty check for the stash popover, so its "Stash current
    /// changes" affordance reflects the tree right now rather than the ≤10s-old sweep
    /// status. Read-only and lock-free; false when the repo isn't cloned.
    func hasLocalChanges(for repo: Repo, in explicitAccount: Account? = nil) async -> Bool {
        guard let account = explicitAccount ?? accountManager.selectedAccount else { return false }
        let path = repoManager.localPath(repo, in: account)
        let gitDir = (path as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else { return false }
        return await runBlocking { GitHub.hasUncommittedChanges(at: path) }
    }

    /// Save the working tree's changes onto the stash stack. Clears the change badge
    /// and adds a stash badge. An optional `message` labels the stash in the list;
    /// blank uses git's auto "WIP on…" text. Logs a friendly note when the tree is
    /// already clean (a no-op). Returns true only when a stash was actually created,
    /// so the caller can keep an unsaved note rather than clear it on a no-op/failure.
    @discardableResult
    func stashPush(_ repo: Repo, message: String = "", in account: Account? = nil) async -> Bool {
        guard let context = beginRepoAction(repo, in: account) else { return false }
        defer { finishRepoAction(context) }
        let account = context.account
        let path = context.path
        logStore.append("Stashing changes in \(repo.name)…")
        let res = await runBlocking { GitHub.stashPush(at: path, message: message) }
        let nothingToStash = res.ok && (res.stdout + res.stderr).contains("No local changes to save")
        if nothingToStash {
            logStore.append("Nothing to stash in \(repo.name) — the working tree is clean.")
        } else {
            logStore.report(res, ok: "stashed changes in \(repo.name)")
        }
        await repoManager.refreshStatuses(for: account)
        return res.ok && !nothingToStash
    }

    /// Restore stash@{index}, keeping it on the stack. `expectedHash` is the SHA the
    /// user saw; a conflicting apply leaves merge markers for them to resolve.
    func stashApply(_ repo: Repo, at index: Int, expectedHash: String, in account: Account? = nil) async {
        await restoreStash(repo, at: index, expectedHash: expectedHash, in: account, running: "apply", done: "applied") {
            GitHub.stashApply(at: $0, index: index)
        }
    }

    /// Restore stash@{index} and drop it on success. Git keeps the stash if applying
    /// conflicts, so a failed pop never loses the parked work.
    func stashPop(_ repo: Repo, at index: Int, expectedHash: String, in account: Account? = nil) async {
        await restoreStash(repo, at: index, expectedHash: expectedHash, in: account, running: "pop", done: "popped") {
            GitHub.stashPop(at: $0, index: index)
        }
    }

    /// Shared apply/pop body. Re-checks that stash@{index} still has `expectedHash`
    /// before acting — the index is positional, so an out-of-band drop/pop (another
    /// row, an external terminal) could otherwise make this hit the wrong stash. The
    /// SHA check and the op run in one off-main hop, so nothing interleaves between
    /// them. On a non-clean restore, says plainly that the stash was kept.
    private func restoreStash(_ repo: Repo, at index: Int, expectedHash: String, in account: Account?,
                              running: String, done: String,
                              _ run: @escaping (String) -> ShellResult) async {
        guard let context = beginRepoAction(repo, in: account) else { return }
        defer { finishRepoAction(context) }
        let account = context.account
        let path = context.path
        logStore.append("Running git stash \(running) stash@{\(index)} in \(repo.name)…")
        let res: ShellResult? = await runBlocking {
            GitHub.stashHash(at: path, index: index) == expectedHash ? run(path) : nil
        }
        guard let res else {
            logStore.append("⚠ \(repo.name): the stash list changed since you opened it — refreshed, nothing applied. Try again.")
            await repoManager.refreshStatuses(for: account)
            return
        }
        logStore.report(res, ok: "\(done) stash@{\(index)} in \(repo.name)")
        if !res.ok {
            logStore.append("⚠ \(repo.name): the stash was kept — resolve the conflicting changes in your working tree, then drop it when you're done.")
        }
        await repoManager.refreshStatuses(for: account)
    }

    /// Discard stash@{index} without restoring it. Destructive — the UI confirms
    /// first, and we re-check `expectedHash` so a stack that shifted out-of-band can
    /// never make this drop the wrong, unrecoverable stash.
    func stashDrop(_ repo: Repo, at index: Int, expectedHash: String, in account: Account? = nil) async {
        guard let context = beginRepoAction(repo, in: account) else { return }
        defer { finishRepoAction(context) }
        let account = context.account
        let path = context.path
        logStore.append("Dropping stash@{\(index)} in \(repo.name)…")
        let res: ShellResult? = await runBlocking {
            GitHub.stashHash(at: path, index: index) == expectedHash ? GitHub.stashDrop(at: path, index: index) : nil
        }
        guard let res else {
            logStore.append("⚠ \(repo.name): the stash list changed since you opened it — refreshed, nothing dropped.")
            await repoManager.refreshStatuses(for: account)
            return
        }
        logStore.report(res, ok: "dropped stash@{\(index)} in \(repo.name)")
        await repoManager.refreshStatuses(for: account)
    }
}
