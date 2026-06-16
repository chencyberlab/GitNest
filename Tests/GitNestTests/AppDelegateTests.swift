import XCTest
@testable import GitNest

final class AppDelegateTests: XCTestCase {
    func testPrimaryProcessIDReturnsSmallestPID() {
        let result = AppDelegate.primaryProcessID(candidatePIDs: [300, 100, 200])
        XCTAssertEqual(result, 100)
    }

    func testPrimaryProcessIDReturnsNilForEmptyCandidateList() {
        let result = AppDelegate.primaryProcessID(candidatePIDs: [])
        XCTAssertNil(result)
    }
}
