import XCTest
@testable import GitNest

final class GitStatusTests: XCTestCase {
    func testRepoStatusParsesAheadBehindAndUpstreamRemote() {
        let output = """
        ## main...origin/main [ahead 2, behind 3]
         M Sources/App.swift
        ?? notes/todo.md
        """

        let status = RepoStatus.parse(porcelainBranch: output)

        XCTAssertEqual(status.changedFiles, 2)
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 3)
        XCTAssertTrue(status.hasUpstream)
        XCTAssertEqual(status.upstreamRemote, "origin")
        XCTAssertTrue(status.isDiverged)
    }

    func testRepoStatusCleanAndCurrentRequiresRemoteCheck() {
        let unchecked = RepoStatus.parse(porcelainBranch: "## main...origin/main")
        let checked = RepoStatus.parse(porcelainBranch: "## main...origin/main", remoteState: .checked)

        XCTAssertFalse(unchecked.isCleanAndCurrent)
        XCTAssertTrue(checked.isCleanAndCurrent)
        XCTAssertFalse(checked.needsAttention)
    }

    func testRepoStatusTreatsRemoteCheckFailureAsAttention() {
        let status = RepoStatus.parse(
            porcelainBranch: "## main...origin/main",
            remoteState: .failed("network unavailable")
        )

        XCTAssertTrue(status.needsAttention)
    }

    func testRepoStatusDetectsGoneUpstream() {
        // `[gone]` means the upstream is configured but its remote branch was
        // deleted — it must never read as clean/current, even after a fetch.
        let status = RepoStatus.parse(
            porcelainBranch: "## main...origin/main [gone]",
            remoteState: .checked
        )

        XCTAssertTrue(status.hasUpstream)
        XCTAssertEqual(status.remoteState, .upstreamGone)
        XCTAssertFalse(status.isCleanAndCurrent)
        XCTAssertTrue(status.needsAttention)
    }

    func testRepoStatusParsesBranchesWithBrackets() {
        // Branch and upstream names containing brackets must not be mistaken for
        // the trailing [ahead/behind] tracking info.
        let output = "## feature/[123]...origin/feature/[123] [ahead 2, behind 1]"

        let status = RepoStatus.parse(porcelainBranch: output)

        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.upstreamRemote, "origin")
    }

    func testRepoStatusDoesNotParseUpstreamBracketsAsTrackingWhenNoTrackingInfo() {
        let output = "## feature/[123]...origin/feature/[123]"

        let status = RepoStatus.parse(porcelainBranch: output)

        XCTAssertEqual(status.ahead, 0)
        XCTAssertEqual(status.behind, 0)
        XCTAssertEqual(status.upstreamRemote, "origin")
        XCTAssertNotEqual(status.remoteState, .upstreamGone)
    }

    func testRepoStatusParsesUpstreamBranchNameWithSpaces() {
        // Upstream branch names can contain spaces; the parser must not split on
        // whitespace inside the upstream reference.
        let output = "## main...origin/my branch [ahead 2]"

        let status = RepoStatus.parse(porcelainBranch: output)

        XCTAssertEqual(status.upstreamRemote, "origin")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertTrue(status.hasUpstream)
    }

    func testRepoStatusHasNoUpstreamRemoteWithoutTrackingBranch() {
        // A branch with no upstream ("## branch" with no "...") must report no
        // upstream and a nil remote — never a spurious remote parsed from the
        // branch name (e.g. "feature/x" must not yield remote "feature").
        let status = RepoStatus.parse(porcelainBranch: "## feature/x")

        XCTAssertFalse(status.hasUpstream)
        XCTAssertNil(status.upstreamRemote)
    }
}
