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

    func testRateLimitBackoffIsTrackedPerOwner() {
        GitHub.clearRateLimitBackoff()
        defer { GitHub.clearRateLimitBackoff() }
        XCTAssertFalse(GitHub.isRateLimited())
        XCTAssertFalse(GitHub.isRateLimited(owner: "me"))

        GitHub.recordRateLimitBackoff(owner: "me", seconds: 60)
        XCTAssertTrue(GitHub.isRateLimited())
        XCTAssertTrue(GitHub.isRateLimited(owner: "me"))
        XCTAssertFalse(GitHub.isRateLimited(owner: "work"))

        GitHub.clearRateLimitBackoff(owner: "me")
        XCTAssertFalse(GitHub.isRateLimited(owner: "me"))
    }

    /// The backoff bookkeeping above is only useful if the *classifier* that feeds
    /// it recognizes the wordings GitHub actually returns. These pin the phrase
    /// matching so a gh message rephrase (or an over-eager "contains") is caught.
    func testIsRateLimitErrorRecognizesGitHubWordings() {
        // Primary limit.
        XCTAssertTrue(GitHub.isRateLimitError("HTTP 403: API rate limit exceeded for user ID 1."))
        // Secondary limit (two common phrasings).
        XCTAssertTrue(GitHub.isRateLimitError("You have exceeded a secondary rate limit. Please wait a few minutes."))
        XCTAssertTrue(GitHub.isRateLimitError("You have exceeded a secondary rate limit and have been temporarily blocked."))
        // Older abuse-detection wording that can omit the words "rate limit".
        XCTAssertTrue(GitHub.isRateLimitError("You have triggered an abuse detection mechanism."))
        // A header echo with the hyphenated spelling.
        XCTAssertTrue(GitHub.isRateLimitError("x-ratelimit-remaining: 0"))
        // Case-insensitive.
        XCTAssertTrue(GitHub.isRateLimitError("API RATE LIMIT EXCEEDED"))
    }

    func testIsRateLimitErrorIgnoresUnrelatedFailures() {
        XCTAssertFalse(GitHub.isRateLimitError("error connecting to api.github.com"))
        XCTAssertFalse(GitHub.isRateLimitError("HTTP 404: Not Found"))
        XCTAssertFalse(GitHub.isRateLimitError("could not resolve host github.com"))
        XCTAssertFalse(GitHub.isRateLimitError(""))
    }

    /// `recordRateLimitIfNeeded` is the bridge used by every gh path (repo list,
    /// ensureActiveAccount's `gh api user`, fork, create) to arm the backoff window.
    /// It must record for a rate-limit failure and stay silent for any other error,
    /// reading the message from stderr (or stdout when stderr is empty).
    func testRecordRateLimitIfNeededArmsBackoffOnlyForRateLimits() {
        GitHub.clearRateLimitBackoff()
        defer { GitHub.clearRateLimitBackoff() }

        GitHub.recordRateLimitIfNeeded(
            ShellResult(exitCode: 1, stdout: "", stderr: "HTTP 404: Not Found"), owner: "a")
        XCTAssertFalse(GitHub.isRateLimited(owner: "a"), "a non-rate-limit error must not arm backoff")

        GitHub.recordRateLimitIfNeeded(
            ShellResult(exitCode: 1, stdout: "", stderr: "You have exceeded a secondary rate limit."), owner: "a")
        XCTAssertTrue(GitHub.isRateLimited(owner: "a"), "a secondary-rate-limit error must arm backoff")
        XCTAssertFalse(GitHub.isRateLimited(owner: "b"), "backoff is per-owner")

        // Falls back to stdout when stderr is empty (some gh paths print there).
        GitHub.clearRateLimitBackoff()
        GitHub.recordRateLimitIfNeeded(
            ShellResult(exitCode: 1, stdout: "API rate limit exceeded", stderr: ""), owner: "c")
        XCTAssertTrue(GitHub.isRateLimited(owner: "c"))
    }

    /// A failed refresh must not claim it's "showing cached repos" when the account
    /// has never loaded successfully and has nothing cached to fall back to (R3).
    func testRepoRefreshFailureMessageReflectsCacheState() {
        XCTAssertEqual(
            RepoManager.repoRefreshFailureMessage(hasCachedRepos: true),
            "Repo refresh failed — showing cached repos.")
        XCTAssertEqual(
            RepoManager.repoRefreshFailureMessage(hasCachedRepos: false),
            "Repo refresh failed — couldn't reach GitHub.")
        XCTAssertFalse(
            RepoManager.repoRefreshFailureMessage(hasCachedRepos: false).contains("cached"),
            "the no-cache message must not promise cached repos that don't exist")
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
