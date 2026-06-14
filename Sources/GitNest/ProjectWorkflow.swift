import SwiftUI
import AppKit

@MainActor
final class ProjectWorkflow: ObservableObject {
    @Published var isInitializingProject = false
    @Published var isForkingProject = false

    private let ghChain: GhChain
    private let logStore: LogStore
    private let repoManager: RepoManager

    init(ghChain: GhChain, logStore: LogStore, repoManager: RepoManager) {
        self.ghChain = ghChain
        self.logStore = logStore
        self.repoManager = repoManager
    }

    func makeInitPlan(sourceURL: URL, account: Account) async -> ProjectInitPlan {
        let sourcePath = sourceURL.standardizedFileURL.path
        let accountFolder = URL(fileURLWithPath: account.folder).standardizedFileURL.path
        let repoName = sanitizedRepoName(from: (sourcePath as NSString).lastPathComponent)
        let blockingReason = sourcePath == accountFolder
            ? "Choose an individual project folder, not the account root folder."
            : nil
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
            blockingReason: blockingReason,
            sourceOrigin: sourceOrigin
        )
    }

    func initProject(_ plan: ProjectInitPlan,
                     visibility: RepoVisibilityChoice,
                     moveOriginalToTrash: Bool = false) async -> Bool {
        isInitializingProject = true
        defer { isInitializingProject = false }
        logStore.append("Initializing \(plan.repoName) for \(plan.account.alias)…")
        let res = await ghChain.serializedPreservingActiveAccount { GitHub.initAndPushProject(plan, visibility: visibility) }
        logStore.report(res, ok: "initialized and pushed \(plan.account.alias)/\(plan.repoName)")
        if res.ok, plan.willCopy, moveOriginalToTrash {
            logStore.append("Moving original folder to Trash…")
            let trash = await runBlocking { FileOps.moveToTrash(plan.sourcePath) }
            logStore.report(trash, ok: "moved original \(plan.sourceName) to Trash")
        }
        await repoManager.refreshClonedStatus(for: plan.account)
        await repoManager.refreshStatuses(for: plan.account, refreshRemote: true)
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

        let forkResult = await ghChain.serializedPreservingActiveAccount { GitHub.fork(source: ref, intoAccount: account.alias) }
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
        let cloneRes = await runBlocking { GitHub.clone(repo: repo, into: account.folder) }
        // A fork you already cloned isn't a failure — the goal (fork present locally
        // with upstream wired up) is already met, so report it calmly and continue.
        let alreadyCloned = !cloneRes.ok && cloneRes.stderr.contains("already exists:")
        if cloneRes.ok {
            logStore.report(cloneRes, ok: "cloned \(repo.name)")
        } else if alreadyCloned {
            logStore.append("ℹ \(repo.name) is already cloned at \(dest).")
        } else {
            logStore.report(cloneRes, ok: "cloned \(repo.name)")
            await repoManager.refreshClonedStatus(for: account)
            await repoManager.refreshStatuses(for: account, refreshRemote: true)
            return false
        }

        let upstream = await runBlocking { GitHub.setUpstream(source: ref, at: dest) }
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
        await repoManager.loadRepos(for: account, silent: true, userInitiated: false)

        return true
    }
}
