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

    func testPrimaryProcessIDForDuplicateReturnsPrimaryWhenCurrentIsSecondary() {
        let result = AppDelegate.primaryProcessIDForDuplicate(currentPID: 300, candidatePIDs: [100, 300])
        XCTAssertEqual(result, 100)
    }

    func testPrimaryProcessIDForDuplicateReturnsNilWhenCurrentIsPrimary() {
        let result = AppDelegate.primaryProcessIDForDuplicate(currentPID: 100, candidatePIDs: [100, 300])
        XCTAssertNil(result)
    }
}
