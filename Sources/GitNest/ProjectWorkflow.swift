import AppKit
import Darwin
import SwiftUI

@MainActor
final class ProjectWorkflow: ObservableObject {
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    @Published var isInitializingProject = false
    @Published var isForkingProject = false

    private let ghChain: GhChain
    private let logStore: LogStore
    private let repoManager: RepoManager
    private let initAndPushProject: @Sendable (ProjectInitPlan, RepoVisibilityChoice) -> ShellResult
    private let forkRepo: @Sendable (RepoReference, String) -> Result<ForkOutcome, CommandError>
    private let cloneRepo: @Sendable (Repo, Account) -> ShellResult
    private let setUpstream: @Sendable (RepoReference, String) -> ShellResult
    private let refreshReposAfterInit: @MainActor (Account) async -> Void
    private let refreshReposAfterFork: @MainActor (Account) async -> Void

    init(ghChain: GhChain,
         logStore: LogStore,
         repoManager: RepoManager,
         initAndPushProject: @escaping @Sendable (ProjectInitPlan, RepoVisibilityChoice) -> ShellResult = {
             GitHub.initAndPushProject($0, visibility: $1)
         },
         forkRepo: @escaping @Sendable (RepoReference, String) -> Result<ForkOutcome, CommandError> = {
             GitHub.fork(source: $0, intoAccount: $1)
         },
         cloneRepo: @escaping @Sendable (Repo, Account) -> ShellResult = {
             GitHub.clone(repo: $0, sshHost: $1.sshHost, into: $1.folder)
         },
         setUpstream: @escaping @Sendable (RepoReference, String) -> ShellResult = {
             GitHub.setUpstream(source: $0, at: $1)
         },
         refreshReposAfterInit: (@MainActor (Account) async -> Void)? = nil,
         refreshReposAfterFork: (@MainActor (Account) async -> Void)? = nil) {
        self.ghChain = ghChain
        self.logStore = logStore
        self.repoManager = repoManager
        self.initAndPushProject = initAndPushProject
        self.forkRepo = forkRepo
        self.cloneRepo = cloneRepo
        self.setUpstream = setUpstream
        self.refreshReposAfterInit = refreshReposAfterInit ?? { [repoManager] account in
            await repoManager.loadRepos(for: account, silent: true, userInitiated: true)
        }
        self.refreshReposAfterFork = refreshReposAfterFork ?? { [repoManager] account in
            await repoManager.loadRepos(for: account, silent: true, userInitiated: false)
        }
    }

    func makeInitPlan(sourceURL: URL, account: Account) async -> ProjectInitPlan {
        let sourcePath = sourceURL.standardizedFileURL.path
        let accountFolder = URL(fileURLWithPath: account.folder).standardizedFileURL.path
        let repoName = sanitizedRepoName(from: (sourcePath as NSString).lastPathComponent)
        let blockingReason = ProjectInitPlan.pathBlockingReason(sourcePath: sourcePath,
                                                                accountFolder: accountFolder)
        let inAccountFolder = sourcePath == accountFolder || sourcePath.hasPrefix(accountFolder + "/")
        let workingPath = inAccountFolder
            ? sourcePath
            : (accountFolder as NSString).appendingPathComponent(repoName)

        // The in-place path refuses on an origin mismatch; the copy path keeps the
        // folder's `.git` and re-points origin, so flag when copying would push a
        // *different* repo's full history. (Local read; doesn't hit the network.)
        var sourceOrigin: String?
        if !inAccountFolder,
           let origin = await runBlocking({ GitHub.originURL(at: sourcePath) }),
           !GitHub.remoteLooksLike(origin, owner: account.alias, repoName: repoName) {
            sourceOrigin = origin
        }

        return ProjectInitPlan(
            account: account,
            sourcePath: sourcePath,
            workingPath: workingPath,
            repoName: repoName,
            willCopy: !inAccountFolder,
            blockingReason: blockingReason
                ?? ProjectInitPlan.copyBlockingReason(sourcePath: sourcePath,
                                                      workingPath: workingPath,
                                                      willCopy: !inAccountFolder),
            sourceOrigin: sourceOrigin
        )
    }

    func initProject(_ plan: ProjectInitPlan,
                     visibility: RepoVisibilityChoice,
                     moveOriginalToTrash: Bool = false) async -> Bool {
        isInitializingProject = true
        defer { isInitializingProject = false }
        let originalSourceIdentity = (plan.willCopy && moveOriginalToTrash)
            ? Self.fileIdentity(at: plan.sourcePath)
            : nil
        logStore.append("Initializing \(plan.repoName) for \(plan.account.alias)…")
        let initAndPushProject = self.initAndPushProject
        let res = await ghChain.serializedPreservingActiveAccount {
            initAndPushProject(plan, visibility)
        }
        logStore.report(res, ok: "initialized and pushed \(plan.account.alias)/\(plan.repoName)")
        if res.ok, plan.willCopy, moveOriginalToTrash {
            guard let originalSourceIdentity,
                  Self.fileIdentity(at: plan.sourcePath) == originalSourceIdentity else {
                logStore.append("⚠ Original folder was not moved to Trash because it changed during initialization.")
                await refreshReposAfterInit(plan.account)
                return res.ok
            }
            logStore.append("Moving original folder to Trash…")
            let trash = await runBlocking { FileOps.moveToTrash(plan.sourcePath) }
            logStore.report(trash, ok: "moved original \(plan.sourceName) to Trash")
        }
        if res.ok {
            await refreshReposAfterInit(plan.account)
        } else {
            await repoManager.refreshClonedStatus(for: plan.account)
            await repoManager.refreshStatuses(for: plan.account, refreshRemote: true)
        }
        return res.ok
    }

    /// Fork a GitHub repository into the selected account and clone it into the
    /// account's folder. Returns `true` when both fork and clone succeeded.
    func forkProject(source: String, account: Account) async -> Bool {
        guard let ref = RepoReference.parse(source) else {
            logStore.append("✗ Invalid GitHub project address: \(source)")
            return false
        }

        isForkingProject = true
        defer { isForkingProject = false }
        logStore.append("Forking \(ref.nameWithOwner) into \(account.alias)'s account…")

        let forkRepo = self.forkRepo
        let forkResult = await ghChain.serializedPreservingActiveAccount { forkRepo(ref, account.alias) }
        guard case .success(let outcome) = forkResult else {
            if case .failure(let error) = forkResult {
                logStore.append("✗ Fork failed: \(error.message)")
            } else {
                logStore.append("✗ Fork failed.")
            }
            return false
        }
        let repo = outcome.repo

        // `gh repo fork` is idempotent: re-forking something you already have just
        // returns the existing fork. Say so plainly instead of implying a fresh one.
        if outcome.alreadyExisted {
            logStore.append("ℹ You already have a fork: \(repo.nameWithOwner). Cloning your existing fork into \(account.folder)…")
        } else {
            logStore.append("✓ Fork created: \(repo.nameWithOwner). Cloning into \(account.folder)…")
        }

        let dest = repoManager.localPath(repo, in: account)
        let cloneRepo = self.cloneRepo
        switch await forkCloneDestinationState(repo: repo, account: account) {
        case .cloned:
            logStore.append("ℹ \(repo.name) is already cloned at \(dest).")
        case .occupied(let conflict):
            logStore.append("✗ Cannot clone \(repo.nameWithOwner): \(conflict.message)")
            await repoManager.refreshClonedStatus(for: account)
            await repoManager.refreshStatuses(for: account, refreshRemote: true)
            return false
        case .absent:
            let cloneRes = await runBlocking { cloneRepo(repo, account) }
            if cloneRes.ok {
                logStore.report(cloneRes, ok: "cloned \(repo.name)")
            } else if case .cloned = await forkCloneDestinationState(repo: repo, account: account) {
                // A concurrent clone may have won the race after our preflight.
                logStore.append("ℹ \(repo.name) is already cloned at \(dest).")
            } else {
                logStore.report(cloneRes, ok: "cloned \(repo.name)")
                await repoManager.refreshClonedStatus(for: account)
                await repoManager.refreshStatuses(for: account, refreshRemote: true)
                return false
            }
        }

        let setUpstream = self.setUpstream
        guard case .cloned = await forkCloneDestinationState(repo: repo, account: account) else {
            logStore.append("✗ Cannot add upstream: \(dest) is no longer a clone of \(repo.nameWithOwner).")
            await repoManager.refreshClonedStatus(for: account)
            await repoManager.refreshStatuses(for: account, refreshRemote: true)
            return false
        }
        let upstream = await runBlocking { setUpstream(ref, dest) }
        let upstreamText = (upstream.stdout + upstream.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if upstream.ok {
            logStore.append("✓ added upstream \(ref.nameWithOwner)" + (upstreamText.isEmpty ? "" : "\n\(upstreamText)"))
        } else {
            logStore.append("⚠ Cloned, but could not add upstream: \(upstreamText.isEmpty ? "unknown error" : upstreamText)")
        }

        // Refresh the repo list so the newly forked repo appears as a row. This
        // already runs refreshClonedStatus + refreshStatuses(refreshRemote:) at the
        // end — and only after `repos` includes the new fork — so doing those here
        // first would just re-fetch every cloned repo's remote a second time.
        await refreshReposAfterFork(account)

        return true
    }

    private func forkCloneDestinationState(repo: Repo, account: Account) async -> LocalRepoFolderState {
        let dest = repoManager.localPath(repo, in: account)
        return await runBlocking {
            AppModel.localFolderState(for: repo, path: dest, expectedSSHHost: account.sshHost)
        }
    }

    private static func fileIdentity(at path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }
}
