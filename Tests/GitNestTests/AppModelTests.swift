import AppKit
import XCTest

@testable import GitNest

@MainActor
final class AppModelTests: XCTestCase {
    func testWorkspaceActivationPausesAndRestartsRefreshTimers() async {
        let model = AppModel()
        defer { model.repoManager.stopAllTimers() }
        model.observeAppActivation()
        model.repoManager.startStatusAutoRefresh(appIsActive: true)
        model.configureRepoAutoRefresh(seconds: 300)
        let info = [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didDeactivateApplicationNotification, object: nil, userInfo: info)
        for _ in 0..<20 where model.appIsActive { await Task.yield() }

        XCTAssertFalse(model.appIsActive)
        XCTAssertFalse(model.repoManager.appIsActive)
        XCTAssertNil(model.repoManager.statusTimer)
        XCTAssertNil(model.repoManager.repoAutoRefreshTimer)
        XCTAssertEqual(model.repoManager.repoAutoRefreshSeconds, 300)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification, object: nil, userInfo: info)
        for _ in 0..<20 where !model.appIsActive { await Task.yield() }

        XCTAssertTrue(model.appIsActive)
        XCTAssertTrue(model.repoManager.appIsActive)
        XCTAssertNotNil(model.repoManager.statusTimer)
        XCTAssertNotNil(model.repoManager.repoAutoRefreshTimer)
    }

    func testCompletingAccountSetupSavesOldStateAndShowsOnlyTheNewAccount() {
        let old = Account(alias: "old", name: "Old", email: "old@example.com", folder: "/tmp/old")
        let new = Account(alias: "new", name: "New", email: "new@example.com", folder: "/tmp/new")
        let model = AppModel(readAccounts: { [old, new] })
        model.accountManager.configureAccountStatusLoadMode(.onDemand)
        model.accountManager.accounts = [old]
        model.accountManager.selectedAccount = old
        for account in [old, new] {
            model.accountManager.sshGreetings[account.alias] = "Hi \(account.alias)!"
            model.accountManager.ghIndicators[account.alias] = .init(ok: true, text: "ready")
        }
        let repo = Repo(
            name: "project", nameWithOwner: "old/project", description: nil,
            visibility: "private", updatedAt: nil, url: "https://github.com/old/project")
        model.repoManager.repos = [repo]
        model.repoManager.clonedRepos = [repo.id]
        model.repoManager.selectedRepo = repo.id
        model.repoManager.repoSearch = "project"
        model.setupCoordinator.beginAddAccount()
        model.setupCoordinator.addAccountIdentity = .init(login: "new", id: 1, name: "New")

        model.completeAddAccount()

        XCTAssertFalse(model.setupCoordinator.addAccountActive)
        XCTAssertEqual(model.accountManager.selectedAccount, new)
        XCTAssertTrue(model.repoManager.repos.isEmpty)
        XCTAssertTrue(model.repoManager.clonedRepos.isEmpty)
        XCTAssertNil(model.repoManager.selectedRepo)
        XCTAssertEqual(model.repoManager.repoCache[old.alias], [repo])
        model.selectAccount(old)
        XCTAssertEqual(model.repoManager.repos, [repo])
        XCTAssertEqual(model.repoManager.selectedRepo, repo.id)
        XCTAssertEqual(model.repoManager.repoSearch, "project")
        XCTAssertEqual(model.repoManager.repoCache[new.alias], [])
    }
}
