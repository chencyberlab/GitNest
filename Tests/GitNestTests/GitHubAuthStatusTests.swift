import XCTest
@testable import GitNest

final class GitHubAuthStatusTests: XCTestCase {
    func testActiveLoginParsesCurrentGhAccountStatusFormat() {
        let output = """
        github.com
          ✓ Logged in to github.com account octo-cat (~/.config/gh/hosts.yml)
          - Active account: true
          - Git operations protocol: ssh
        """

        XCTAssertEqual(GitHub.activeLogin(fromAuthStatus: output), "octo-cat")
    }

    func testActiveLoginForRestoreParsesNonZeroAuthStatusOutput() {
        let result = ShellResult(exitCode: 1, stdout: "", stderr: """
        github.com
          ✓ Logged in to github.com account octo-cat (~/.config/gh/hosts.yml)
          - Active account: true
          X Token is expired
        """)

        XCTAssertEqual(GitHub.activeLoginForRestore(fromAuthStatusResult: result), "octo-cat")
    }

    func testActiveLoginPrefersAccountMarkedActiveWhenMultipleAccountsArePrinted() {
        let output = """
        github.com
          ✓ Logged in to github.com account old-account (~/.config/gh/hosts.yml)
          - Active account: false
          ✓ Logged in to github.com account active-account (~/.config/gh/hosts.yml)
          - Active account: true
        """

        XCTAssertEqual(GitHub.activeLogin(fromAuthStatus: output), "active-account")
    }

    func testActiveLoginParsesLegacyGhAccountStatusFormat() {
        let output = """
        github.com
          ✓ Logged in to github.com as monalisa (keyring)
          ✓ Git operations for github.com configured to use ssh protocol.
        """

        XCTAssertEqual(GitHub.activeLogin(fromAuthStatus: output), "monalisa")
    }

    func testActiveLoginRejectsMalformedLogin() {
        let output = "✓ Logged in to github.com account ../bad (~/.config/gh/hosts.yml)"

        XCTAssertNil(GitHub.activeLogin(fromAuthStatus: output))
    }
}
