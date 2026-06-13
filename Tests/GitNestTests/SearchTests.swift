import XCTest
@testable import GitNest

final class SearchTests: XCTestCase {
    func testWildcardMatcherMatchesSubstringGlobAndSubsequence() {
        let haystacks = ["MultiGitManager", "owner/tools", "A compact repo dashboard"]

        XCTAssertTrue(WildcardMatcher.matches(query: "git", haystacks: haystacks))
        XCTAssertTrue(WildcardMatcher.matches(query: "m*g*manager", haystacks: haystacks))
        XCTAssertTrue(WildcardMatcher.matches(query: "mgm", haystacks: haystacks))
        XCTAssertFalse(WildcardMatcher.matches(query: "zzzz", haystacks: haystacks))
    }

    func testWildcardMatcherRequiresEveryTokenToMatchSomewhere() {
        XCTAssertTrue(WildcardMatcher.matches(query: "owner dash", haystacks: ["owner/tools", "dashboard"]))
        XCTAssertFalse(WildcardMatcher.matches(query: "owner missing", haystacks: ["owner/tools", "dashboard"]))
    }

    func testRepoAndAccountSearchDelegateToSharedMatcher() {
        let repo = Repo(
            name: "tools",
            nameWithOwner: "owner/tools",
            description: "Repository dashboard",
            visibility: "private",
            updatedAt: nil,
            url: "https://github.com/owner/tools"
        )
        let account = Account(
            alias: "owner",
            name: "Owner Name",
            email: "owner@example.com",
            folder: "/Users/example/github_owner"
        )

        XCTAssertTrue(RepoSearch.matches(query: "repo dash", repo: repo))
        XCTAssertTrue(AccountSearch.matches(query: "own github", account: account))
    }
}
