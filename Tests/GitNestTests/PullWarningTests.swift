import XCTest
@testable import GitNest

final class PullWarningTests: XCTestCase {
    func testMessageIncludesRepoNameAndReassurance() {
        let msg = AppModel.PullWarning.message(
            repoName: "demo",
            gitOutput: "error: Your local changes would be overwritten by merge."
        )
        XCTAssertTrue(msg.contains("demo"))
        XCTAssertTrue(msg.contains("not force-replaced"))
        XCTAssertTrue(msg.contains("error: Your local changes would be overwritten by merge."))
    }

    func testMessageFallsBackWhenOutputIsBlank() {
        let msg = AppModel.PullWarning.message(repoName: "demo", gitOutput: "   \n\t  ")
        XCTAssertTrue(msg.contains("Git did not provide details."))
    }

    func testMessageTruncatesLongOutputAndPointsToOutputPane() {
        let long = String(repeating: "x", count: 5000)
        let msg = AppModel.PullWarning.message(repoName: "demo", gitOutput: long)
        XCTAssertTrue(msg.contains("Full output is in the Output pane."))
        // The raw payload is capped at 1200 chars, so the full 5000-char run is gone.
        XCTAssertFalse(msg.contains(String(repeating: "x", count: 1201)))
    }
}
