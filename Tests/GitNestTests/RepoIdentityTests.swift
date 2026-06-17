import XCTest
@testable import GitNest

@MainActor
final class RepoIdentityTests: XCTestCase {
    func testClonedStateUsesNameWithOwnerInsteadOfRepoNameOnly() {
        let model = AppModel()
        let mine = repo(owner: "me", name: "tools")
        let shared = repo(owner: "friend", name: "tools")

        model.repoManager.clonedRepos = [mine.id]

        XCTAssertTrue(model.repoManager.isCloned(mine))
        XCTAssertFalse(model.repoManager.isCloned(shared))
    }

    func testRefreshClonedStatusReportsSameNameFolderConflict() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let account = Account(alias: "me",
                              name: "Me",
                              email: "me@example.com",
                              folder: root.path)
        let mine = repo(owner: "me", name: "tools")
        let shared = repo(owner: "friend", name: "tools")
        let localRepo = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: localRepo, withIntermediateDirectories: true)

        XCTAssertTrue(Shell.run(["git", "init"], cwd: localRepo.path).ok)
        XCTAssertTrue(Shell.run([
            "git", "remote", "add", "origin", "https://github.com/friend/tools.git"
        ], cwd: localRepo.path).ok)

        let model = AppModel()
        model.accountManager.selectedAccount = account
        model.repoManager.repos = [mine, shared]

        await model.repoManager.refreshClonedStatus(for: account)

        XCTAssertFalse(model.repoManager.isCloned(mine))
        XCTAssertTrue(model.repoManager.isCloned(shared))
        XCTAssertEqual(model.repoManager.folderConflict(mine)?.origin, "https://github.com/friend/tools.git")
        XCTAssertNil(model.repoManager.folderConflict(shared))
    }

    func testRefreshClonedStatusReportsWrongAccountSSHAliasAsConflict() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let account = Account(alias: "me",
                              name: "Me",
                              email: "me@example.com",
                              folder: root.path)
        let target = repo(owner: "me", name: "tools")
        let localRepo = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: localRepo, withIntermediateDirectories: true)

        XCTAssertTrue(Shell.run(["git", "init"], cwd: localRepo.path).ok)
        XCTAssertTrue(Shell.run([
            "git", "remote", "add", "origin", "git@github-work:me/tools.git"
        ], cwd: localRepo.path).ok)

        let model = AppModel()
        model.accountManager.selectedAccount = account
        model.repoManager.repos = [target]

        await model.repoManager.refreshClonedStatus(for: account)

        XCTAssertFalse(model.repoManager.isCloned(target))
        XCTAssertEqual(model.repoManager.folderConflict(target)?.origin, "git@github-work:me/tools.git")
    }

    func testBusyRepoActionCoversRowsSharingTheSameLocalPath() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let account = Account(alias: "me",
                              name: "Me",
                              email: "me@example.com",
                              folder: root.path)
        let mine = repo(owner: "me", name: "tools")
        let shared = repo(owner: "friend", name: "tools")
        let localRepo = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: localRepo, withIntermediateDirectories: true)

        XCTAssertTrue(Shell.run(["git", "init"], cwd: localRepo.path).ok)
        XCTAssertTrue(Shell.run(["git", "config", "user.name", "Test User"], cwd: localRepo.path).ok)
        XCTAssertTrue(Shell.run(["git", "config", "user.email", "test@example.com"], cwd: localRepo.path).ok)
        XCTAssertTrue(Shell.run([
            "git", "remote", "add", "origin", "https://github.com/me/tools.git"
        ], cwd: localRepo.path).ok)

        let file = localRepo.appendingPathComponent("README.md")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)
        let hook = localRepo
            .appendingPathComponent(".git")
            .appendingPathComponent("hooks")
            .appendingPathComponent("pre-commit")
        try "#!/bin/sh\nsleep 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let model = AppModel()
        model.accountManager.selectedAccount = account
        model.repoManager.repos = [mine, shared]
        model.repoManager.clonedRepos = [mine.id, shared.id]

        let task = Task { await model.repoActionCoordinator.commit(mine, message: "Initial commit") }
        var attempts = 0
        while attempts < 100 && !model.repoActionCoordinator.isRepoActionBusy(shared) {
            attempts += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(model.repoActionCoordinator.isRepoActionBusy(mine))
        XCTAssertTrue(model.repoActionCoordinator.isRepoActionBusy(shared))

        await task.value

        XCTAssertFalse(model.repoActionCoordinator.isRepoActionBusy(mine))
        XCTAssertFalse(model.repoActionCoordinator.isRepoActionBusy(shared))
    }

    func testRepoActionCanStayScopedToOriginalAccountAfterSelectionChanges() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let accountA = Account(alias: "me",
                               name: "Me",
                               email: "me@example.com",
                               folder: root.appendingPathComponent("me").path)
        let accountB = Account(alias: "work",
                               name: "Work",
                               email: "work@example.com",
                               folder: root.appendingPathComponent("work").path)
        let target = repo(owner: "me", name: "tools")
        let repoA = URL(fileURLWithPath: accountA.folder).appendingPathComponent("tools")
        let repoB = URL(fileURLWithPath: accountB.folder).appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: repoA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB, withIntermediateDirectories: true)

        for repoURL in [repoA, repoB] {
            XCTAssertTrue(Shell.run(["git", "init"], cwd: repoURL.path).ok)
            XCTAssertTrue(Shell.run(["git", "config", "user.name", "Test User"], cwd: repoURL.path).ok)
            XCTAssertTrue(Shell.run(["git", "config", "user.email", "test@example.com"], cwd: repoURL.path).ok)
        }
        XCTAssertTrue(Shell.run([
            "git", "remote", "add", "origin", "https://github.com/me/tools.git"
        ], cwd: repoA.path).ok)
        XCTAssertTrue(Shell.run([
            "git", "remote", "add", "origin", "https://github.com/work/tools.git"
        ], cwd: repoB.path).ok)
        try "from account A\n".write(to: repoA.appendingPathComponent("README.md"),
                                     atomically: true,
                                     encoding: .utf8)

        let model = AppModel()
        model.accountManager.accounts = [accountA, accountB]
        model.accountManager.selectedAccount = accountB
        model.repoManager.repos = [target]
        model.repoManager.repoCache[accountA.alias] = [target]
        model.repoManager.clonedReposCache[accountA.alias] = [target.id]

        await model.repoActionCoordinator.commit(target, message: "Commit in account A", in: accountA)

        let accountALog = Shell.run(["git", "log", "-1", "--pretty=%s"], cwd: repoA.path)
        let accountBHead = Shell.run(["git", "rev-parse", "--verify", "HEAD"], cwd: repoB.path)
        XCTAssertTrue(accountALog.ok)
        XCTAssertEqual(accountALog.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "Commit in account A")
        XCTAssertFalse(accountBHead.ok)
    }

    func testCloneStateForExplicitAccountDoesNotUseVisibleAccountState() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let accountA = Account(alias: "me",
                               name: "Me",
                               email: "me@example.com",
                               folder: root.appendingPathComponent("me").path)
        let accountB = Account(alias: "work",
                               name: "Work",
                               email: "work@example.com",
                               folder: root.appendingPathComponent("work").path)
        let existing = repo(owner: "me", name: "existing")
        let target = repo(owner: "me", name: "tools")
        let visible = repo(owner: "work", name: "dashboard")
        let targetFolder = URL(fileURLWithPath: accountA.folder).appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)

        XCTAssertTrue(Shell.run(["git", "init"], cwd: targetFolder.path).ok)
        XCTAssertTrue(Shell.run([
            "git", "remote", "add", "origin", "https://github.com/me/tools.git"
        ], cwd: targetFolder.path).ok)

        let model = AppModel()
        model.accountManager.accounts = [accountA, accountB]
        model.accountManager.selectedAccount = accountB
        model.repoManager.repos = [visible]
        model.repoManager.clonedRepos = [visible.id]
        model.repoManager.repoFolderConflicts = [
            visible.id: RepoFolderConflict(path: "/tmp/visible-conflict", origin: nil)
        ]
        model.repoManager.repoCache[accountA.alias] = [existing, target]
        model.repoManager.clonedReposCache[accountA.alias] = [existing.id]

        await model.repoActionCoordinator.clone(target, in: accountA)

        XCTAssertEqual(model.repoManager.clonedRepos, [visible.id])
        XCTAssertFalse(model.repoManager.clonedReposCache[accountA.alias]?.contains(visible.id) == true)
        XCTAssertTrue(model.repoManager.clonedReposCache[accountA.alias]?.contains(existing.id) == true)
        XCTAssertTrue(model.repoManager.clonedReposCache[accountA.alias]?.contains(target.id) == true)
    }

    func testMutatingRepoActionRefusesStaleCloneStateForDifferentOrigin() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let account = Account(alias: "me",
                              name: "Me",
                              email: "me@example.com",
                              folder: root.path)
        let target = repo(owner: "me", name: "tools")
        let localRepo = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: localRepo, withIntermediateDirectories: true)

        XCTAssertTrue(Shell.run(["git", "init"], cwd: localRepo.path).ok)
        XCTAssertTrue(Shell.run(["git", "config", "user.name", "Test User"], cwd: localRepo.path).ok)
        XCTAssertTrue(Shell.run(["git", "config", "user.email", "test@example.com"], cwd: localRepo.path).ok)
        XCTAssertTrue(Shell.run([
            "git", "remote", "add", "origin", "https://github.com/other/tools.git"
        ], cwd: localRepo.path).ok)
        try "do not commit\n".write(to: localRepo.appendingPathComponent("README.md"),
                                    atomically: true,
                                    encoding: .utf8)

        let model = AppModel()
        model.accountManager.selectedAccount = account
        model.repoManager.repos = [target]
        model.repoManager.clonedRepos = [target.id]

        await model.repoActionCoordinator.commit(target, message: "Should not commit")

        XCTAssertFalse(Shell.run(["git", "rev-parse", "--verify", "HEAD"], cwd: localRepo.path).ok)
        XCTAssertTrue(model.logStore.log.contains("no longer a clone of me/tools"))
    }

    private func repo(owner: String, name: String) -> Repo {
        Repo(
            name: name,
            nameWithOwner: "\(owner)/\(name)",
            description: nil,
            visibility: "private",
            updatedAt: nil,
            url: "https://github.com/\(owner)/\(name)"
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitNestRepoIdentityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
