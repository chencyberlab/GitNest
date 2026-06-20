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

    func testMasksTokenInURLUserInfoWithoutPassword() {
        // A credential carried as the whole userinfo (no password half) must still be
        // masked, even when it isn't a recognized gh*/github_pat prefix.
        let scrubbed = Redaction.scrub("remote https://0123456789abcdef0123@github.com/o/r.git")
        XCTAssertEqual(scrubbed, "remote https://\(Redaction.mask)@github.com/o/r.git")
    }

    func testDoesNotMaskBareCommitSHA() {
        // A 40-char hex commit SHA in body text is not a credential — the userinfo
        // rule must not fire on it (this is why bare-hex masking was deliberately avoided).
        let text = "merged at 0123456789abcdef0123456789abcdef01234567"
        XCTAssertEqual(Redaction.scrub(text), text)
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

    func testCommandErrorDisplayMessageIsRedacted() {
        let error = CommandError(message: "failed with github_pat_abcdefghijklmnopqrstuvwxyz0123456789ABCD")

        XCTAssertTrue(error.displayMessage.contains(Redaction.mask))
        XCTAssertFalse(error.displayMessage.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
    }

    func testAuthStatusNeverRequestsTheToken() {
        // The output is logged; gh masks the token only when not asked to show it.
        XCTAssertEqual(GitHub.authStatusArgs(), ["gh", "auth", "status"])
        XCTAssertFalse(GitHub.authStatusArgs().contains("--show-token"))
    }

    // MARK: Multi-secret / interaction hardening
    //
    // The single-token cases above don't exercise the parts most likely to regress:
    // several secrets on one line, a secret next to a path that then home-folds, and
    // the ordering between the token rules and the URL-userinfo rule. These pin them.

    /// Two distinct tokens on one line must BOTH be masked (a single global pass,
    /// not just the first match), each keeping its own identifying prefix.
    func testMasksEveryTokenOnALineNotJustTheFirst() {
        let a = "abcdefghijklmnop0000"   // ≥16 chars
        let b = "ABCDEFGHIJKLMNOP1111"
        let scrubbed = Redaction.scrub("first ghp_\(a) then gho_\(b) done")
        XCTAssertEqual(scrubbed, "first ghp_\(Redaction.mask) then gho_\(Redaction.mask) done")
    }

    /// A token and a home path on the same line: the token is masked AND the home
    /// dir is folded — the two rules must compose, not clobber each other.
    func testMasksTokenAndFoldsHomePathTogether() {
        let home = NSHomeDirectory()
        let scrubbed = Redaction.scrub("\(home)/.config/gh holds ghp_abcdefghijklmnop2222")
        XCTAssertEqual(scrubbed, "~/.config/gh holds ghp_\(Redaction.mask)")
    }

    /// A gh-prefixed token carried as URL userinfo (`https://ghp_…@host`).
    ///
    /// The security-critical property — the secret body never survives — holds: it
    /// is fully masked. This pins the OBSERVED behavior: the trailing URL-userinfo
    /// rule re-masks the (already prefix-masked) userinfo segment, so the `ghp_`
    /// prefix is dropped here and the result is `https://‹redacted›@…`. That diverges
    /// from the inline comment in Redaction.swift, which claims the prefix is kept in
    /// this case. The test pins reality and flags the divergence so a future change
    /// to either the rule order or that comment is a conscious decision, not a silent
    /// drift. (If prefix preservation is later implemented, update this assertion.)
    func testTokenInURLUserInfoIsFullyMaskedEvenIfPrefixNotKept() {
        let body = "abcdefghijklmnopqrstuvwxyz0123"
        let scrubbed = Redaction.scrub("remote https://ghp_\(body)@github.com/o/r.git")
        XCTAssertFalse(scrubbed.contains(body), "the secret body must never survive")
        XCTAssertTrue(scrubbed.contains(Redaction.mask))
        XCTAssertEqual(scrubbed, "remote https://\(Redaction.mask)@github.com/o/r.git")
    }
}
