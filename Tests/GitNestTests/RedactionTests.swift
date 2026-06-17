import XCTest
@testable import GitNest

final class RedactionTests: XCTestCase {
    func testMasksGitHubTokenFormatsButKeepsPrefix() {
        let body = "abcdefghijklmnopqrstuvwxyz0123456789ABCD"   // 40 chars, > the 16 minimum
        for prefix in ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"] {
            let scrubbed = Redaction.scrub("token is \(prefix)\(body) here")
            XCTAssertEqual(scrubbed, "token is \(prefix)\(Redaction.mask) here")
        }
        let pat = Redaction.scrub("github_pat_\(body)")
        XCTAssertEqual(pat, "github_pat_\(Redaction.mask)")
    }

    func testDoesNotMaskShortTokenLookalikes() {
        // Too short to be a real token — must not be over-masked.
        XCTAssertEqual(Redaction.scrub("ghp_short"), "ghp_short")
    }

    func testMasksCredentialsInURLUserInfoButKeepsUser() {
        let scrubbed = Redaction.scrub("remote https://alice:s3cr3t-value@github.com/o/r.git")
        XCTAssertEqual(scrubbed, "remote https://alice:\(Redaction.mask)@github.com/o/r.git")
    }

    func testFoldsHomeDirectoryToTilde() {
        let home = NSHomeDirectory()
        XCTAssertEqual(Redaction.scrub("backed up \(home)/.ssh/config"), "backed up ~/.ssh/config")
    }

    func testDoesNotFoldSiblingDirectoryWithSharedPrefix() {
        let home = NSHomeDirectory()
        // A sibling whose name merely starts with the home dir's must be left intact —
        // only `<home>/…` is a real boundary.
        let sibling = "at \(home)2/repo and \(home)-backup/x"
        XCTAssertEqual(Redaction.scrub(sibling), sibling)
    }

    func testLeavesOrdinaryTextUntouched() {
        let text = "✓ pulled repo — 3 files changed"
        XCTAssertEqual(Redaction.scrub(text), text)
    }

    func testAuthStatusNeverRequestsTheToken() {
        // The output is logged; gh masks the token only when not asked to show it.
        XCTAssertEqual(GitHub.authStatusArgs(), ["gh", "auth", "status"])
        XCTAssertFalse(GitHub.authStatusArgs().contains("--show-token"))
    }
}
