import XCTest
@testable import GitNest

/// The linchpin of the whole multi-account model: before any `gh` operation runs
/// for an account, `ensureActiveAccount` switches to it and then *verifies via the
/// live API* that the active login really is that account — refusing on any
/// mismatch. If that verification is ever weakened (e.g. "trust the switch exit
/// code"), operations could silently land on the wrong account, defeating the
/// app's entire reason to exist. The real function shells out to `gh`, so these
/// drive the injectable core (`verifyActiveAccount`) with stubbed switch/identity
/// results — network-free, deterministic, and exercising every branch.
final class EnsureActiveAccountTests: XCTestCase {
    private func ok(_ stdout: String = "", _ stderr: String = "") -> ShellResult {
        ShellResult(exitCode: 0, stdout: stdout, stderr: stderr)
    }
    private func fail(_ stderr: String) -> ShellResult {
        ShellResult(exitCode: 1, stdout: "", stderr: stderr)
    }

    /// The switch succeeds but the verified identity is a *different* account — the
    /// exact silent-wrong-account scenario this guard exists to stop. Must refuse,
    /// and the message must name both the actual and expected logins.
    func testRefusesWhenActiveLoginDiffersFromExpected() {
        var identityChecked = false
        let res = GitHub.verifyActiveAccount(
            "work",
            switchAccount: { _ in self.ok() },   // switch "succeeded"…
            activeLogin: {                       // …but the verified identity is wrong
                identityChecked = true
                return self.ok("personal\n")
            }
        )

        XCTAssertFalse(res.ok, "a verified-wrong active account must be refused")
        XCTAssertTrue(identityChecked, "the identity must be verified, not assumed from the switch")
        XCTAssertTrue(res.stderr.contains("personal"), "message should name the actual login")
        XCTAssertTrue(res.stderr.contains("work"), "message should name the expected login")
        XCTAssertTrue(res.stderr.contains("Refusing to continue"))
    }

    /// The happy path: switch succeeds and the verified login matches. Comparison is
    /// case-insensitive (GitHub logins are), so an alias casing difference still
    /// passes rather than spuriously refusing.
    func testAcceptsMatchingLoginCaseInsensitively() {
        let res = GitHub.verifyActiveAccount(
            "Work",
            switchAccount: { _ in self.ok() },
            activeLogin: { self.ok("work\n") }
        )

        XCTAssertTrue(res.ok)
        XCTAssertTrue(res.stdout.contains("work"))
    }

    /// `gh auth switch` itself failing (account logged out, gh broken) must short-
    /// circuit: the verifying API call must NOT run, and the switch failure is
    /// returned verbatim so the caller can surface it.
    func testReturnsSwitchFailureWithoutVerifying() {
        var identityChecked = false
        let res = GitHub.verifyActiveAccount(
            "work",
            switchAccount: { _ in self.fail("could not switch to work: not logged in") },
            activeLogin: {
                identityChecked = true
                return self.ok("work\n")
            }
        )

        XCTAssertFalse(res.ok)
        XCTAssertFalse(identityChecked, "must not verify identity after a failed switch")
        XCTAssertTrue(res.stderr.contains("not logged in"))
    }

    /// The unhappy path the review flagged: the switch is a local op (no network)
    /// and can succeed while the *verifying* API call fails (rate limit, offline,
    /// expired token). The function must fail **closed** — never treat an
    /// unverifiable switch as success — so downstream callers (listRepos, fork,
    /// init) abort rather than act as an unverified identity.
    func testFailsClosedWhenIdentityCheckErrors() {
        let res = GitHub.verifyActiveAccount(
            "work",
            switchAccount: { _ in self.ok() },
            activeLogin: { self.fail("HTTP 403: API rate limit exceeded") }
        )

        XCTAssertFalse(res.ok, "an unverifiable switch must fail closed, not pass")
        XCTAssertTrue(res.stderr.contains("rate limit"))
    }

    /// An empty login from the API (parsed nothing) is still a mismatch — it must
    /// not be coerced into "matches" — and is reported as `unknown` rather than a
    /// blank in the message.
    func testTreatsEmptyVerifiedLoginAsMismatch() {
        let res = GitHub.verifyActiveAccount(
            "work",
            switchAccount: { _ in self.ok() },
            activeLogin: { self.ok("   \n") }   // whitespace only → trims to empty
        )

        XCTAssertFalse(res.ok)
        XCTAssertTrue(res.stderr.contains("unknown"))
        XCTAssertTrue(res.stderr.contains("expected work"))
    }
}
