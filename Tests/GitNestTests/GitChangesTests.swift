import XCTest
@testable import GitNest

final class GitChangesTests: XCTestCase {
    func testClassifyCoversTheCommonPorcelainCodes() {
        XCTAssertEqual(GitChanges.classify("?", "?"), .untracked)
        XCTAssertEqual(GitChanges.classify(" ", "M"), .modified)
        XCTAssertEqual(GitChanges.classify("M", " "), .modified)
        XCTAssertEqual(GitChanges.classify("A", " "), .added)
        XCTAssertEqual(GitChanges.classify(" ", "D"), .deleted)
        XCTAssertEqual(GitChanges.classify("R", " "), .renamed)
        XCTAssertEqual(GitChanges.classify("C", " "), .renamed)
        XCTAssertEqual(GitChanges.classify(" ", "T"), .modified)
    }

    func testClassifyTreatsUnmergedStatesAsConflicted() {
        XCTAssertEqual(GitChanges.classify("U", "U"), .conflicted)
        XCTAssertEqual(GitChanges.classify("A", "A"), .conflicted)
        XCTAssertEqual(GitChanges.classify("D", "D"), .conflicted)
        XCTAssertEqual(GitChanges.classify("U", "D"), .conflicted)
        XCTAssertEqual(GitChanges.classify("A", "U"), .conflicted)
    }

    func testClassifyFallsBackToOtherWithRawCode() {
        XCTAssertEqual(GitChanges.classify("X", "Y"), .other("XY"))
    }

    func testParseHandlesPathsWithSpacesAndStatuses() {
        // -z records are NUL-terminated (\u{0}), not newline-separated.
        let output = " M Sources/App State.swift\u{0}?? notes/todo.md\u{0} D OldConfig.json\u{0}A  Added.swift\u{0}"
        let changes = GitChanges.parse(porcelainZ: output)

        XCTAssertEqual(changes.count, 4)
        XCTAssertEqual(changes[0].path, "Sources/App State.swift")
        XCTAssertEqual(changes[0].status, .modified)
        XCTAssertEqual(changes[1].path, "notes/todo.md")
        XCTAssertEqual(changes[1].status, .untracked)
        XCTAssertEqual(changes[2].status, .deleted)
        XCTAssertEqual(changes[3].path, "Added.swift")
        XCTAssertEqual(changes[3].status, .added)
    }

    func testParseSplitsRenamesIntoOriginalAndNewPath() {
        // -z emits the new path first, then a second NUL-terminated original path.
        let changes = GitChanges.parse(porcelainZ: "R  new/name.swift\u{0}old/name.swift\u{0}")

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].status, .renamed)
        XCTAssertEqual(changes[0].originalPath, "old/name.swift")
        XCTAssertEqual(changes[0].path, "new/name.swift")
    }

    func testParseDoesNotMistakeArrowsInFilenamesForRenames() {
        // A file literally named "weird -> name.txt": -z keeps it as one record, so
        // it stays a single untracked entry instead of being split into a rename.
        let changes = GitChanges.parse(porcelainZ: "?? weird -> name.txt\u{0}")

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].status, .untracked)
        XCTAssertEqual(changes[0].path, "weird -> name.txt")
        XCTAssertNil(changes[0].originalPath)
    }

    func testParseHandlesPathsWithNewlinesAndQuotes() {
        // -z never quotes/escapes, so control chars and quotes pass through verbatim.
        let changes = GitChanges.parse(porcelainZ: " M weird\n\"name\".txt\u{0}")

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].path, "weird\n\"name\".txt")
    }

    func testParseIgnoresEmptyRecords() {
        XCTAssertTrue(GitChanges.parse(porcelainZ: "\u{0}\u{0}").isEmpty)
        XCTAssertTrue(GitChanges.parse(porcelainZ: "").isEmpty)
    }

    func testGroupedOrdersGroupsAndSortsFilesWithinThem() {
        let output = "?? z-untracked.txt\u{0} M b.swift\u{0} M a.swift\u{0} D gone.txt\u{0}"
        let groups = GitChanges.grouped(GitChanges.parse(porcelainZ: output))

        XCTAssertEqual(groups.map(\.title), ["Modified", "Deleted", "Untracked"])
        XCTAssertEqual(groups[0].files.map(\.path), ["a.swift", "b.swift"])
    }

    func testGroupedCollapsesOtherCodesUnderOneHeading() {
        // Two different unusual codes should land in a single "Other" group.
        let groups = GitChanges.grouped([
            GitFileChange(path: "one", originalPath: nil, status: .other("XY")),
            GitFileChange(path: "two", originalPath: nil, status: .other("ZZ")),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].title, "Other")
        XCTAssertEqual(groups[0].files.count, 2)
    }
}
