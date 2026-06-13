import XCTest
@testable import GitNest

@MainActor
final class RepoIdentityTests: XCTestCase {
    func testClonedStateUsesNameWithOwnerInsteadOfRepoNameOnly() {
        let model = AppModel()
        let mine = repo(owner: "me", name: "tools")
        let shared = repo(owner: "friend", name: "tools")

        model.clonedRepos = [mine.id]

        XCTAssertTrue(model.isCloned(mine))
        XCTAssertFalse(model.isCloned(shared))
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
        model.selectedAccount = account
        model.repos = [mine, shared]

        await model.refreshClonedStatus(for: account)

        XCTAssertFalse(model.isCloned(mine))
        XCTAssertTrue(model.isCloned(shared))
        XCTAssertEqual(model.folderConflict(mine)?.origin, "https://github.com/friend/tools.git")
        XCTAssertNil(model.folderConflict(shared))
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

        let file = localRepo.appendingPathComponent("README.md")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)
        let hook = localRepo
            .appendingPathComponent(".git")
            .appendingPathComponent("hooks")
            .appendingPathComponent("pre-commit")
        try "#!/bin/sh\nsleep 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let model = AppModel()
        model.selectedAccount = account
        model.repos = [mine, shared]
        model.clonedRepos = [mine.id, shared.id]

        let task = Task { await model.commit(mine, message: "Initial commit") }
        var attempts = 0
        while attempts < 100 && !model.isRepoActionBusy(shared) {
            attempts += 1
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(model.isRepoActionBusy(mine))
        XCTAssertTrue(model.isRepoActionBusy(shared))

        await task.value

        XCTAssertFalse(model.isRepoActionBusy(mine))
        XCTAssertFalse(model.isRepoActionBusy(shared))
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
        try "from account A\n".write(to: repoA.appendingPathComponent("README.md"),
                                     atomically: true,
                                     encoding: .utf8)

        let model = AppModel()
        model.accounts = [accountA, accountB]
        model.selectedAccount = accountB
        model.repos = [target]
        model.repoCache[accountA.alias] = [target]
        model.clonedReposCache[accountA.alias] = [target.id]

        await model.commit(target, message: "Commit in account A", in: accountA)

        let accountALog = Shell.run(["git", "log", "-1", "--pretty=%s"], cwd: repoA.path)
        let accountBHead = Shell.run(["git", "rev-parse", "--verify", "HEAD"], cwd: repoB.path)
        XCTAssertTrue(accountALog.ok)
        XCTAssertEqual(accountALog.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "Commit in account A")
        XCTAssertFalse(accountBHead.ok)
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
