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
}
