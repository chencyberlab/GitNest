import XCTest
@testable import GitNest

final class ForkProjectTests: XCTestCase {
    func testRepoReferenceParsesHTTPSURL() {
        let ref = RepoReference.parse("https://github.com/owner/repo")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
        XCTAssertEqual(ref?.nameWithOwner, "owner/repo")
    }

    func testRepoReferenceParsesHTTPSURLWithGitSuffix() {
        let ref = RepoReference.parse("https://github.com/owner/repo.git")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    func testRepoReferenceParsesHTTPSURLWithTrailingSlash() {
        let ref = RepoReference.parse("https://github.com/owner/repo/")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    func testRepoReferenceParsesHTTPURL() {
        let ref = RepoReference.parse("http://github.com/owner/repo")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    func testRepoReferenceParsesBareGitHubHost() {
        let ref = RepoReference.parse("github.com/owner/repo")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    func testRepoReferenceParsesSSHForm() {
        let ref = RepoReference.parse("git@github.com:owner/repo.git")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    func testRepoReferenceParsesOwnerRepoShorthand() {
        let ref = RepoReference.parse("owner/repo")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }

    func testRepoReferenceAllowsValidRepoPunctuation() {
        let ref = RepoReference.parse("owner/repo--name_1.2")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo--name_1.2")
    }

    func testRepoReferenceRejectsEmptyInput() {
        XCTAssertNil(RepoReference.parse(""))
        XCTAssertNil(RepoReference.parse("   "))
    }

    func testRepoReferenceRejectsMissingOwnerOrRepo() {
        XCTAssertNil(RepoReference.parse("repo"))
        XCTAssertNil(RepoReference.parse("/repo"))
        XCTAssertNil(RepoReference.parse("owner/"))
    }

    func testRepoReferenceRejectsGitHubPageURLs() {
        XCTAssertNil(RepoReference.parse("https://github.com/owner/repo/tree/main"))
        XCTAssertNil(RepoReference.parse("https://github.com/owner/repo/issues/1"))
        XCTAssertNil(RepoReference.parse("https://github.com/owner/repo/pull/1"))
    }

    func testRepoReferenceRejectsNonGitHubHost() {
        XCTAssertNil(RepoReference.parse("https://gitlab.com/owner/repo"))
        XCTAssertNil(RepoReference.parse("git@gitlab.com:owner/repo.git"))
    }

    func testRepoReferenceRejectsInvalidOwnerNames() {
        XCTAssertNil(RepoReference.parse("bad_owner/repo"))
        XCTAssertNil(RepoReference.parse("-owner/repo"))
        XCTAssertNil(RepoReference.parse("owner-/repo"))
        XCTAssertNil(RepoReference.parse("owner--name/repo"))
    }

    func testRepoReferenceRejectsInvalidRepoNames() {
        XCTAssertNil(RepoReference.parse("owner/Repo Name"))
        XCTAssertNil(RepoReference.parse("owner/."))
        XCTAssertNil(RepoReference.parse("owner/.."))
    }

    func testRepoReferenceTrimsWhitespace() {
        let ref = RepoReference.parse("  https://github.com/owner/repo  ")
        XCTAssertEqual(ref?.owner, "owner")
        XCTAssertEqual(ref?.repo, "repo")
    }
}
