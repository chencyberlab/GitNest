import XCTest
@testable import GitNest

final class GitStashTests: XCTestCase {
    /// Build one entry the way `git stash list -z --format=%gd%x1f%gs` does.
    private func record(_ selector: String, _ subject: String) -> String {
        [selector, subject].joined(separator: "\u{1f}")
    }

    func testParsesMultipleStashes() {
        // `git stash list -z` NUL-separates entries.
        let output = [
            record("stash@{0}", "WIP on feature: d7b3e3a add tracked"),
            record("stash@{1}", "On feature: my first stash: stuff & things"),
        ].joined(separator: "\u{0}")

        let entries = GitStash.parse(listZ: output)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].index, 0)
        XCTAssertEqual(entries[0].selector, "stash@{0}")
        XCTAssertEqual(entries[0].subject, "WIP on feature: d7b3e3a add tracked")
        XCTAssertEqual(entries[1].index, 1)
        XCTAssertEqual(entries[1].subject, "On feature: my first stash: stuff & things")
    }

    func testToleratesTrailingNUL() {
        // git emits a trailing NUL after the last stash entry — it must not become
        // an empty entry.
        let output = record("stash@{0}", "WIP on main: abc") + "\u{0}"
        let entries = GitStash.parse(listZ: output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].index, 0)
    }

    func testKeepsSubjectWithSeparatorsAndPunctuation() {
        let output = record("stash@{3}", "On main: feat: add (x), commas & colons")
        let entries = GitStash.parse(listZ: output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].index, 3)
        XCTAssertEqual(entries[0].subject, "On main: feat: add (x), commas & colons")
    }

    func testSkipsRecordMissingSubject() {
        // A record with no field separator (selector only) is dropped, not misread.
        let output = "stash@{0}" + "\u{0}" + record("stash@{1}", "ok")
        let entries = GitStash.parse(listZ: output)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].index, 1)
    }

    func testSkipsUnparseableSelector() {
        XCTAssertTrue(GitStash.parse(listZ: record("notastash", "subject")).isEmpty)
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
