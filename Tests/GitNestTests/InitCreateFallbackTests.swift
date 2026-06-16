import XCTest
@testable import GitNest

/// The init flow adopts a pre-existing repo only when `gh repo create` actually
/// reported a name collision. This pins the classifier so a future change can't
/// regress to "any create failure means the repo already exists" — which would
/// mask real errors (rate limit, auth, network) and push into the wrong repo.
final class InitCreateFallbackTests: XCTestCase {
    private func result(stderr: String) -> ShellResult {
        ShellResult(exitCode: 1, stdout: "", stderr: stderr)
    }

    func testRecognizesNameCollision() {
        XCTAssertTrue(GitHub.createReportedNameCollision(
            result(stderr: "GraphQL: Name already exists on this account (createRepository)")))
        XCTAssertTrue(GitHub.createReportedNameCollision(
            result(stderr: "name already exists on this account")))
    }

    func testDoesNotTreatOtherFailuresAsCollision() {
        XCTAssertFalse(GitHub.createReportedNameCollision(
            result(stderr: "HTTP 403: API rate limit exceeded")))
        XCTAssertFalse(GitHub.createReportedNameCollision(
            result(stderr: "error connecting to api.github.com")))
        XCTAssertFalse(GitHub.createReportedNameCollision(
            result(stderr: "You are not authorized to create repositories")))
        XCTAssertFalse(GitHub.createReportedNameCollision(result(stderr: "")))
    }
}
