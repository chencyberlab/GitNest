import XCTest
import SwiftUI
@testable import GitNest

@MainActor
final class CoordinatorTests: XCTestCase {
    // MARK: LogStore

    func testLogStoreAppendsMessages() {
        let store = LogStore()
        store.append("hello")
        store.append("world")
        XCTAssertTrue(store.log.contains("hello"))
        XCTAssertTrue(store.log.contains("world"))
        XCTAssertFalse(store.lastWasError)
    }

    func testLogStoreMarksErrorsAndWarnings() {
        let store = LogStore()
        store.append("✗ failed")
        XCTAssertTrue(store.lastWasError)
        store.append("normal")
        XCTAssertFalse(store.lastWasError)
        store.append("⚠ warning")
        XCTAssertTrue(store.lastWasError)
    }

    func testLogStoreEnforcesMaxLines() {
        let store = LogStore()
        for i in 0..<(LogStore.maxLogLines + 10) {
            store.append("line \(i)")
        }
        var lines = store.log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        XCTAssertEqual(lines.count, LogStore.maxLogLines)
    }

    func testLogStoreReportSuccess() {
        let store = LogStore()
        let result = ShellResult(exitCode: 0, stdout: "out", stderr: "err")
        store.report(result, ok: "done")
        XCTAssertTrue(store.log.contains("✓ done"))
        XCTAssertTrue(store.log.contains("out"))
        XCTAssertTrue(store.log.contains("err"))
    }

    func testLogStoreReportFailure() {
        let store = LogStore()
        let result = ShellResult(exitCode: 1, stdout: "", stderr: "boom")
        store.report(result, ok: "done")
        XCTAssertTrue(store.log.contains("✗ boom"))
        XCTAssertTrue(store.lastWasError)
    }

    // MARK: AppModel re-publishing

    func testAddAccountSheetDismissalRoutesThroughCancel() {
        let model = AppModel()
        model.setupCoordinator.beginAddAccount()
        model.setupCoordinator.addAccountBusy = true
        let session = model.setupCoordinator.addAccountSessionID

        model.setupCoordinator.addAccountActiveBinding.wrappedValue = false

        XCTAssertFalse(model.setupCoordinator.addAccountActive)
        XCTAssertFalse(model.setupCoordinator.addAccountBusy)
        XCTAssertNotEqual(model.setupCoordinator.addAccountSessionID, session)
    }

    func testAddAccountErrorIsRedacted() {
        let model = AppModel()

        model.setupCoordinator.setAddAccountError("token ghp_abcdefghijklmnopqrstuvwxyz0123456789ABCD leaked")

        XCTAssertTrue(model.setupCoordinator.addAccountError?.contains(Redaction.mask) == true)
        XCTAssertFalse(model.setupCoordinator.addAccountError?.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD") == true)
    }

    func testAppModelDismissPullWarningRoutesThroughAlertStore() async {
        let model = AppModel()
        model.alertStore.showPullWarning(AlertStore.PullWarning(repoName: "tools", message: "boom"))
        await Task.yield()
        XCTAssertNotNil(model.alertStore.pullWarning)

        model.alertStore.dismissPullWarning()
        await Task.yield()

        XCTAssertNil(model.alertStore.pullWarning)
    }

    // MARK: AlertStore

    func testAlertStoreShowsAndDismissesPullWarning() {
        let store = AlertStore()
        let warning = AlertStore.PullWarning(repoName: "tools", message: "boom")
        store.showPullWarning(warning)
        XCTAssertEqual(store.pullWarning?.repoName, "tools")
        store.dismissPullWarning()
        XCTAssertNil(store.pullWarning)
    }

    // MARK: RepoManager filtering

    func testRepoManagerFiltersAndSortsRepos() {
        let repos = [
            Repo(name: "alpha", nameWithOwner: "me/alpha", description: nil, visibility: "private", updatedAt: "2026-01-01T00:00:00Z", url: ""),
            Repo(name: "beta", nameWithOwner: "me/beta", description: nil, visibility: "private", updatedAt: "2026-01-02T00:00:00Z", url: ""),
            Repo(name: "gamma", nameWithOwner: "me/gamma", description: nil, visibility: "private", updatedAt: "2026-01-03T00:00:00Z", url: "")
        ]
        let filtered = RepoManager.filteredRepos(
            query: "beta",
            repos: repos,
            clonedRepos: ["me/alpha"],
            sortField: .updated,
            sortAscending: false
        )
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.name, "beta")
    }

    func testRepoManagerPinsClonedReposOnTop() {
        let repos = [
            Repo(name: "aaa", nameWithOwner: "me/aaa", description: nil, visibility: "private", updatedAt: "2026-01-01T00:00:00Z", url: ""),
            Repo(name: "zzz", nameWithOwner: "me/zzz", description: nil, visibility: "private", updatedAt: "2026-01-02T00:00:00Z", url: "")
        ]
        let filtered = RepoManager.filteredRepos(
            query: "",
            repos: repos,
            clonedRepos: ["me/zzz"],
            sortField: .name,
            sortAscending: true
        )
        XCTAssertEqual(filtered.map(\.name), ["zzz", "aaa"])
    }

    // MARK: AccountManager ordering

    func testAccountManagerOrdersAccountsBySavedOrder() {
        let manager = AccountManager(ghChain: GhChain(),
                                     logStore: LogStore(),
                                     authProcessController: AuthProcessController())
        let loaded = [
            Account(alias: "work", name: "Work", email: "w@example.com", folder: "/w"),
            Account(alias: "personal", name: "Personal", email: "p@example.com", folder: "/p"),
            Account(alias: "org", name: "Org", email: "o@example.com", folder: "/o")
        ]
        UserDefaults.standard.set(["org", "personal"], forKey: AccountManager.accountOrderDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: AccountManager.accountOrderDefaultsKey) }

        let ordered = manager.orderedAccounts(loaded)
        XCTAssertEqual(ordered.map(\.alias), ["org", "personal", "work"])
    }

    func testAccountManagerSavesAccountOrder() {
        let manager = AccountManager(ghChain: GhChain(),
                                     logStore: LogStore(),
                                     authProcessController: AuthProcessController())
        manager.accounts = [
            Account(alias: "z", name: "Z", email: "z@example.com", folder: "/z"),
            Account(alias: "a", name: "A", email: "a@example.com", folder: "/a")
        ]
        manager.saveAccountOrder()
        defer { UserDefaults.standard.removeObject(forKey: AccountManager.accountOrderDefaultsKey) }

        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: AccountManager.accountOrderDefaultsKey), ["z", "a"])
    }

    func testRepoActionBusyPathKeyPreservesCaseOnCaseSensitiveVolumes() {
        XCTAssertEqual(
            RepoActionCoordinator.busyPathKey(for: "/Users/me/Work/Tools", caseSensitiveOverride: true),
            "/Users/me/Work/Tools"
        )
    }

    func testRepoActionBusyPathKeyFoldsCaseOnCaseInsensitiveVolumes() {
        XCTAssertEqual(
            RepoActionCoordinator.busyPathKey(for: "/Users/me/Work/Tools", caseSensitiveOverride: false),
            "/users/me/work/tools"
        )
    }

    func testRepoActionBusyPathKeyUsesExistingAncestorForMissingPaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitNestBusyPathTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let values = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard let isCaseSensitive = values.volumeSupportsCaseSensitiveNames else {
            throw XCTSkip("volume case-sensitivity is unavailable")
        }
        let missingPath = root
            .appendingPathComponent("Tools")
            .appendingPathComponent("Repo")
            .path
        let expected = isCaseSensitive ? missingPath : missingPath.lowercased()

        XCTAssertEqual(RepoActionCoordinator.busyPathKey(for: missingPath), expected)
    }
}
