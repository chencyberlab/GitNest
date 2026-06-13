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
}
