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
