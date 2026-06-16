import XCTest
@testable import GitNest

final class RepoListTests: XCTestCase {
    func testListReposFailsClosedWhenAccountCannotBeVerified() {
        var ownedReposCalled = false
        var collaboratorReposCalled = false
        var organizationMemberReposCalled = false

        let result = GitHub.listRepos(
            owner: "me",
            ensureActive: { _ in
                ShellResult(exitCode: 1, stdout: "", stderr: "switch failed")
            },
            ownedRepos: {
                ownedReposCalled = true
                return .success([])
            },
            collaboratorRepos: {
                collaboratorReposCalled = true
                return []
            },
            organizationMemberRepos: {
                organizationMemberReposCalled = true
                return []
            }
        )

        guard case .failure(let error) = result else {
            return XCTFail("Expected account verification failure")
        }
        XCTAssertEqual(error.message, "switch failed")
        XCTAssertFalse(ownedReposCalled)
        XCTAssertFalse(collaboratorReposCalled)
        XCTAssertFalse(organizationMemberReposCalled)
    }

    func testListReposMergesOwnedCollaboratorAndOrganizationReposByID() {
        let mine = repo(owner: "me", name: "tools", updatedAt: "2026-01-01T00:00:00Z")
        let shared = repo(owner: "friend", name: "tools", updatedAt: "2026-02-01T00:00:00Z")
        let org = repo(owner: "acme", name: "shared", updatedAt: "2026-03-01T00:00:00Z")

        let result = GitHub.listRepos(
            owner: "me",
            ensureActive: { _ in ShellResult(exitCode: 0, stdout: "gh active account: me", stderr: "") },
            ownedRepos: { .success([mine]) },
            collaboratorRepos: { [shared, mine] },
            organizationMemberRepos: { [org, mine] }
        )

        guard case .success(let repos) = result else {
            return XCTFail("Expected merged repo list")
        }
        XCTAssertEqual(repos.map(\.id), [org.id, shared.id, mine.id])
    }

    func testDecodeSlurpedRestReposHandlesPaginatedOutput() {
        let json = """
        [
          [
            {
              "name": "one",
              "full_name": "me/one",
              "description": null,
              "visibility": "private",
              "private": true,
              "updated_at": "2026-01-01T00:00:00Z",
              "html_url": "https://github.com/me/one"
            }
          ],
          [
            {
              "name": "two",
              "full_name": "friend/two",
              "description": "Shared",
              "visibility": "public",
              "private": false,
              "updated_at": "2026-01-02T00:00:00Z",
              "html_url": "https://github.com/friend/two"
            }
          ]
        ]
        """

        let repos = GitHub.decodeSlurpedRestRepos(json)

        XCTAssertEqual(repos?.map(\.nameWithOwner), ["me/one", "friend/two"])
        XCTAssertEqual(repos?.map(\.visibility), ["private", "public"])
    }

    func testRateLimitBackoffSuppressesAutoRefresh() {
        GitHub.clearRateLimitBackoff()
        defer { GitHub.clearRateLimitBackoff() }
        XCTAssertFalse(GitHub.isRateLimited())

        GitHub.recordRateLimitBackoff(seconds: 60)
        XCTAssertTrue(GitHub.isRateLimited())

        GitHub.clearRateLimitBackoff()
        XCTAssertFalse(GitHub.isRateLimited())
    }

    private func repo(owner: String, name: String, updatedAt: String) -> Repo {
        Repo(
            name: name,
            nameWithOwner: "\(owner)/\(name)",
            description: nil,
            visibility: "private",
            updatedAt: updatedAt,
            url: "https://github.com/\(owner)/\(name)"
        )
    }
}
