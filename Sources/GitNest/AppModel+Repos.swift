import SwiftUI
import AppKit

extension AppModel {
    // MARK: Account readiness proxies

    func accountReady(_ account: Account) -> Bool {
        accountManager.accountReady(account)
    }

    func accountChecking(_ account: Account) -> Bool {
        accountManager.accountChecking(account)
    }

    func accountStatusKnown(_ account: Account) -> Bool {
        accountManager.accountStatusKnown(account)
    }

    func accountSSHReady(_ account: Account) -> Bool {
        accountManager.accountSSHReady(account)
    }

    func accountGhReady(_ account: Account) -> Bool {
        accountManager.accountGhReady(account)
    }

    // MARK: Repo loading proxies

    func loadRepos(for account: Account, silent: Bool = false, userInitiated: Bool = true) async {
        await repoManager.loadRepos(for: account, silent: silent, userInitiated: userInitiated)
    }

    func refreshClonedStatus(for account: Account) async {
        await repoManager.refreshClonedStatus(for: account)
    }

    func refreshStatuses(for account: Account, refreshRemote: Bool = false) async {
        await repoManager.refreshStatuses(for: account, refreshRemote: refreshRemote)
    }

    func commitCloneState(_ cloned: Set<Repo.ID>,
                          _ conflicts: [Repo.ID: RepoFolderConflict],
                          for alias: String) {
        repoManager.commitCloneState(cloned, conflicts, for: alias)
    }

    // MARK: Per-repo state proxies

    func localPath(_ repo: Repo, in account: Account) -> String {
        repoManager.localPath(repo, in: account)
    }

    func isCloned(_ repo: Repo) -> Bool {
        repoManager.isCloned(repo)
    }

    func folderConflict(_ repo: Repo) -> RepoFolderConflict? {
        repoManager.folderConflict(repo)
    }

}
