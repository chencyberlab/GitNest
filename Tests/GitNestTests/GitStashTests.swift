import XCTest
@testable import GitNest

final class GitStashTests: XCTestCase {
    /// Build one entry the way `git stash list -z --format=%gd%x1f%H%x1f%gs` does.
    private func record(_ selector: String, _ hash: String, _ subject: String) -> String {
        [selector, hash, subject].joined(separator: "\u{1f}")
    }

    func testParsesMultipleStashes() {
        // `git stash list -z` NUL-separates entries.
        let output = [
            record("stash@{0}", "aaaa111bbbb222", "WIP on feature: d7b3e3a add tracked"),
            record("stash@{1}", "cccc333dddd444", "On feature: my first stash: stuff & things"),
        ].joined(separator: "\u{0}")

        let entries = GitStash.parse(listZ: output)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].index, 0)
        XCTAssertEqual(entries[0].selector, "stash@{0}")
        XCTAssertEqual(entries[0].hash, "aaaa111bbbb222")
        XCTAssertEqual(entries[0].subject, "WIP on feature: d7b3e3a add tracked")
        XCTAssertEqual(entries[1].index, 1)
        XCTAssertEqual(entries[1].hash, "cccc333dddd444")
        XCTAssertEqual(entries[1].subject, "On feature: my first stash: stuff & things")
    }

    func testToleratesTrailingNUL() {
        // git emits a trailing NUL after the last stash entry — it must not become
        // an empty entry.
        let output = record("stash@{0}", "abc123", "WIP on main: abc") + "\u{0}"
        let entries = GitStash.parse(listZ: output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].index, 0)
        XCTAssertEqual(entries[0].hash, "abc123")
    }

    func testKeepsSubjectWithSeparatorsAndPunctuation() {
        let output = record("stash@{3}", "deadbeef", "On main: feat: add (x), commas & colons")
        let entries = GitStash.parse(listZ: output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].index, 3)
        XCTAssertEqual(entries[0].subject, "On main: feat: add (x), commas & colons")
    }

    func testSkipsRecordMissingSubject() {
        // A record with only selector + hash (no subject field) is dropped, not misread.
        let malformed = ["stash@{0}", "abc123"].joined(separator: "\u{1f}")
        let output = malformed + "\u{0}" + record("stash@{1}", "def456", "ok")
        let entries = GitStash.parse(listZ: output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].index, 1)
    }

    func testSkipsRecordWithEmptyHash() {
        // An empty SHA field can't anchor the re-validation guard, so it's dropped.
        XCTAssertTrue(GitStash.parse(listZ: record("stash@{0}", "", "subject")).isEmpty)
    }

    func testSkipsUnparseableSelector() {
        XCTAssertTrue(GitStash.parse(listZ: record("notastash", "abc123", "subject")).isEmpty)
    }

    func testEmptyOutputYieldsNoStashes() {
        XCTAssertTrue(GitStash.parse(listZ: "").isEmpty)
        XCTAssertTrue(GitStash.parse(listZ: "\u{0}").isEmpty)
    }

    func testIndexParsing() {
        XCTAssertEqual(GitStash.index(from: "stash@{0}"), 0)
        XCTAssertEqual(GitStash.index(from: "stash@{10}"), 10)
        XCTAssertNil(GitStash.index(from: "stash@{}"))
        XCTAssertNil(GitStash.index(from: "garbage"))
    }
}
