import XCTest
@testable import GitNest

final class ForkProjectTests: XCTestCase {
    func testForkedRepoNameUsesActualCreatedForkFromOutput() {
        let output = "✓ Created fork me/repo-1\nhttps://github.com/me/repo-1"

        XCTAssertEqual(
            GitHub.forkedRepoNameWithOwner(from: output, currentUser: "me", fallbackRepo: "repo"),
            "me/repo-1"
        )
    }

    func testForkedRepoNameIgnoresSourceRepoAndFallsBackWhenAbsent() {
        XCTAssertEqual(
            GitHub.forkedRepoNameWithOwner(
                from: "Forking source/repo into your account...",
                currentUser: "me",
                fallbackRepo: "repo"
            ),
            "me/repo"
        )
    }

    func testForkedRepoNameParsesGitURLWithGitSuffix() {
        XCTAssertEqual(
            GitHub.forkedRepoNameWithOwner(
                from: "remote: https://github.com/me/repo-2.git",
                currentUser: "me",
                fallbackRepo: "repo"
            ),
            "me/repo-2"
        )
    }

    func testForkedRepoNameCandidatesIncludeRenamedForkBeforeFallback() {
        let candidates = GitHub.forkedRepoNameCandidates(
            from: "fork already exists: https://github.com/me/repo-3",
            currentUser: "me",
            fallbackRepo: "repo"
        )

        XCTAssertEqual(candidates, ["me/repo-3", "me/repo"])
    }

    func testRepoViewDetailsVerifiesForkParent() {
        let source = RepoReference(owner: "source", repo: "repo", raw: "source/repo")
        let repo = Repo(
            name: "repo-3",
            nameWithOwner: "me/repo-3",
            description: nil,
            visibility: "public",
            updatedAt: nil,
            url: "https://github.com/me/repo-3"
        )

        XCTAssertTrue(RepoViewDetails(repo: repo, parentNameWithOwner: "source/repo").isFork(of: source))
        XCTAssertTrue(RepoViewDetails(repo: repo, parentNameWithOwner: "SOURCE/REPO").isFork(of: source))
        XCTAssertFalse(RepoViewDetails(repo: repo, parentNameWithOwner: "other/repo").isFork(of: source))
        XCTAssertFalse(RepoViewDetails(repo: repo, parentNameWithOwner: nil).isFork(of: source))
    }

    func testDecodeRepoViewDetailsParsesGitHubForkParentShape() {
        // The exact JSON `gh repo view --json …,parent` emits for a fork: the
        // parent is a nested {name, owner:{login}} object with NO flat
        // `nameWithOwner`. A decoder that required `parent.nameWithOwner` threw,
        // `try?` swallowed it, and every fork looked "not available" for 60s.
        let json = """
        {"name":"awesome-design-md","nameWithOwner":"chencyberlab/awesome-design-md",\
        "parent":{"id":"R_kgDOR2Chew","name":"awesome-design-md",\
        "owner":{"id":"O_kgDOC_9TSg","login":"VoltAgent"}},\
        "url":"https://github.com/chencyberlab/awesome-design-md","visibility":"PUBLIC"}
        """

        let details = GitHub.decodeRepoViewDetails(fromJSON: json)
        XCTAssertNotNil(details, "fork payload must decode")
        XCTAssertEqual(details?.repo.nameWithOwner, "chencyberlab/awesome-design-md")
        XCTAssertEqual(details?.parentNameWithOwner, "VoltAgent/awesome-design-md")

        let source = RepoReference(owner: "VoltAgent", repo: "awesome-design-md",
                                   raw: "VoltAgent/awesome-design-md")
        XCTAssertEqual(details?.isFork(of: source), true)
    }

    func testDecodeRepoViewDetailsParsesNonForkWithNullParent() {
        let json = """
        {"name":"GitNest","nameWithOwner":"chencyberlab/GitNest","parent":null,\
        "url":"https://github.com/chencyberlab/GitNest","visibility":"PUBLIC"}
        """

        let details = GitHub.decodeRepoViewDetails(fromJSON: json)
        XCTAssertNotNil(details)
        XCTAssertNil(details?.parentNameWithOwner)
    }

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
