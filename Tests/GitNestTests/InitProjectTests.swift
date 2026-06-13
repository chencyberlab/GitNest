import XCTest
@testable import GitNest

final class InitProjectTests: XCTestCase {
    func testRemoteLooksLikeMatchesCommonURLForms() {
        XCTAssertTrue(GitHub.remoteLooksLike("https://github.com/owner/repo.git", owner: "owner", repoName: "repo"))
        XCTAssertTrue(GitHub.remoteLooksLike("https://github.com/owner/repo", owner: "owner", repoName: "repo"))
        XCTAssertTrue(GitHub.remoteLooksLike("git@github.com:owner/repo.git", owner: "owner", repoName: "repo"))
        XCTAssertTrue(GitHub.remoteLooksLike("git@github-work:owner/repo.git", owner: "owner", repoName: "repo"))
    }

    func testRemoteLooksLikeIsCaseInsensitive() {
        XCTAssertTrue(GitHub.remoteLooksLike("git@GitHub.com:Owner/Repo.git", owner: "owner", repoName: "repo"))
    }

    func testRemoteLooksLikeRejectsOtherOwnersAndRepos() {
        XCTAssertFalse(GitHub.remoteLooksLike("git@github.com:other/repo.git", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("git@github.com:owner/other.git", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("git@gitlab.com:owner/repo.git", owner: "owner", repoName: "repo"))
    }

    func testRemoteLooksLikeRequiresExactOwnerRepoPath() {
        XCTAssertFalse(GitHub.remoteLooksLike("git@github.com:owner/repo-old.git", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("https://github.com/owner/repo-extra", owner: "owner", repoName: "repo"))
        XCTAssertFalse(GitHub.remoteLooksLike("https://github.com/owner/repo/tree/main", owner: "owner", repoName: "repo"))
    }

    func testRemoteLooksLikeKeepsDotGitInsideRepoNames() {
        // ".git" must only be stripped from the end — a Pages repo contains it
        // in the middle of its name and used to be mangled into "ownerhub.io".
        XCTAssertTrue(GitHub.remoteLooksLike(
            "git@github-me:owner/owner.github.io.git",
            owner: "owner", repoName: "owner.github.io"
        ))
        XCTAssertTrue(GitHub.remoteLooksLike(
            "https://github.com/owner/my.gitops.git",
            owner: "owner", repoName: "my.gitops"
        ))
    }
}
