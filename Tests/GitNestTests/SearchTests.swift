import XCTest
@testable import GitNest

final class SearchTests: XCTestCase {
    func testWildcardMatcherMatchesSubstringGlobAndSubsequence() {
        // WildcardMatcher expects pre-lowercased haystacks; callers (Repo/Account)
        // cache them to avoid re-lowercasing on every keystroke.
        let haystacks = ["multigitmanager", "owner/tools", "a compact repo dashboard"]

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

    /// The working-diff search matches one compiled query against tens of thousands
    /// of lines, so compiling must be equivalent to the per-call path it replaces.
    func testCompiledQueryMatchesTheSameWayAsTheOneShotCall() {
        let haystacks = ["multigitmanager", "owner/tools"]
        for query in ["git", "m*g*manager", "mgm", "owner tools", "zzzz", "  "] {
            XCTAssertEqual(
                WildcardMatcher.matches(WildcardMatcher.compile(query), haystacks: haystacks),
                WildcardMatcher.matches(query: query, haystacks: haystacks),
                "compiled and one-shot disagree on \(query)")
        }
    }

    /// `.literal` exists for long text (diff lines), where fuzzy subsequence
    /// matching hits nearly everything. Substring and glob still work there.
    func testLiteralStrictnessDropsFuzzySubsequenceButKeepsSubstringAndGlob() {
        let line = ["let newaccountvalue = refresh()"]
        let fuzzy = WildcardMatcher.compile("nacv")
        XCTAssertTrue(WildcardMatcher.matches(fuzzy, haystacks: line))
        XCTAssertFalse(WildcardMatcher.matches(fuzzy, haystacks: line, strictness: .literal))

        XCTAssertTrue(
            WildcardMatcher.matches(WildcardMatcher.compile("account"), haystacks: line, strictness: .literal))
        XCTAssertTrue(
            WildcardMatcher.matches(WildcardMatcher.compile("let*refresh*"), haystacks: line, strictness: .literal))
        XCTAssertTrue(
            WildcardMatcher.matches(WildcardMatcher.compile(""), haystacks: line, strictness: .literal))
    }
}
