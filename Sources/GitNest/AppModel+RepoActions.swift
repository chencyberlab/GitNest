import SwiftUI
import AppKit

extension AppModel {
    // MARK: Busy-state proxy

    func isRepoActionBusy(_ repo: Repo) -> Bool {
        repoActionCoordinator.isRepoActionBusy(repo)
    }

    // MARK: Per-repo action proxies

    func clone(_ repo: Repo, in account: Account? = nil) async {
        await repoActionCoordinator.clone(repo, in: account)
    }

    func pull(_ repo: Repo, in account: Account? = nil) async {
        await repoActionCoordinator.pull(repo, in: account)
    }

    func fetch(_ repo: Repo, in account: Account? = nil) async {
        await repoActionCoordinator.fetch(repo, in: account)
    }

    func push(_ repo: Repo, in account: Account? = nil) async {
        await repoActionCoordinator.push(repo, in: account)
    }

    func openGitHubRepo(_ repo: Repo) {
        repoActionCoordinator.openGitHubRepo(repo)
    }

    func openLocalFolder(_ repo: Repo, in explicitAccount: Account? = nil) {
        repoActionCoordinator.openLocalFolder(repo, in: explicitAccount)
    }

    func openInEditor(_ repo: Repo,
                      in explicitAccount: Account? = nil,
                      editor: PreferredEditor,
                      customAppName: String) async {
        await repoActionCoordinator.openInEditor(repo,
                                                 in: explicitAccount,
                                                 editor: editor,
                                                 customAppName: customAppName)
    }

    func openInTerminal(_ repo: Repo,
                        in explicitAccount: Account? = nil,
                        terminal: PreferredTerminal,
                        customAppName: String) async {
        await repoActionCoordinator.openInTerminal(repo,
                                                   in: explicitAccount,
                                                   terminal: terminal,
                                                   customAppName: customAppName)
    }

    func changedFiles(for repo: Repo,
                      in explicitAccount: Account? = nil) async -> Result<[GitFileChange], CommandError> {
        await repoActionCoordinator.changedFiles(for: repo, in: explicitAccount)
    }

    func recentCommits(for repo: Repo,
                       in explicitAccount: Account? = nil) async -> Result<[GitCommit], CommandError> {
        await repoActionCoordinator.recentCommits(for: repo, in: explicitAccount)
    }

    func incomingCommits(for repo: Repo,
                         in explicitAccount: Account? = nil) async -> Result<[GitCommit], CommandError> {
        await repoActionCoordinator.incomingCommits(for: repo, in: explicitAccount)
    }

    func deleteLocalFolder(_ repo: Repo, in account: Account? = nil) async {
        await repoActionCoordinator.deleteLocalFolder(repo, in: account)
    }

    func commit(_ repo: Repo, message: String, in account: Account? = nil) async {
        await repoActionCoordinator.commit(repo, message: message, in: account)
    }

    // MARK: Stash proxies

    func stashList(for repo: Repo, in explicitAccount: Account? = nil) async -> Result<[GitStashEntry], CommandError> {
        await repoActionCoordinator.stashList(for: repo, in: explicitAccount)
    }

    func hasLocalChanges(for repo: Repo, in explicitAccount: Account? = nil) async -> Bool {
        await repoActionCoordinator.hasLocalChanges(for: repo, in: explicitAccount)
    }

    @discardableResult
    func stashPush(_ repo: Repo, message: String = "", in account: Account? = nil) async -> Bool {
        await repoActionCoordinator.stashPush(repo, message: message, in: account)
    }

    func stashApply(_ repo: Repo, at index: Int, expectedHash: String, in account: Account? = nil) async {
        await repoActionCoordinator.stashApply(repo, at: index, expectedHash: expectedHash, in: account)
    }

    func stashPop(_ repo: Repo, at index: Int, expectedHash: String, in account: Account? = nil) async {
        await repoActionCoordinator.stashPop(repo, at: index, expectedHash: expectedHash, in: account)
    }

    func stashDrop(_ repo: Repo, at index: Int, expectedHash: String, in account: Account? = nil) async {
        await repoActionCoordinator.stashDrop(repo, at: index, expectedHash: expectedHash, in: account)
    }

    // MARK: Account re-authentication proxy

    func reauthenticateGh(for account: Account) async {
        await accountManager.reauthenticateGh(for: account)
    }

    // MARK: Project workflow proxies

    func makeInitPlan(sourceURL: URL, account: Account) async -> ProjectInitPlan {
        await projectWorkflow.makeInitPlan(sourceURL: sourceURL, account: account)
    }

    func initProject(_ plan: ProjectInitPlan,
                     visibility: RepoVisibilityChoice,
                     moveOriginalToTrash: Bool = false) async -> Bool {
        await projectWorkflow.initProject(plan, visibility: visibility, moveOriginalToTrash: moveOriginalToTrash)
    }

    func forkProject(source: String, account: Account) async -> Bool {
        await projectWorkflow.forkProject(source: source, account: account)
    }
}
