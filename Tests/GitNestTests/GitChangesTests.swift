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
        let output = """
         M Sources/App State.swift
        ?? notes/todo.md
         D OldConfig.json
        A  Added.swift
        """
        let changes = GitChanges.parse(porcelain: output)

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
        let changes = GitChanges.parse(porcelain: "R  old/name.swift -> new/name.swift")

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].status, .renamed)
        XCTAssertEqual(changes[0].originalPath, "old/name.swift")
        XCTAssertEqual(changes[0].path, "new/name.swift")
    }

    func testParseUnquotesPathsWithEscapes() {
        // git quotes paths containing a double quote even with quotePath disabled.
        let changes = GitChanges.parse(porcelain: " M \"weird \\\"name\\\".txt\"")

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].path, "weird \"name\".txt")
    }

    func testParseIgnoresBlankLines() {
        XCTAssertTrue(GitChanges.parse(porcelain: "\n\n").isEmpty)
        XCTAssertTrue(GitChanges.parse(porcelain: "").isEmpty)
    }

    func testGroupedOrdersGroupsAndSortsFilesWithinThem() {
        let output = """
        ?? z-untracked.txt
         M b.swift
         M a.swift
         D gone.txt
        """
        let groups = GitChanges.grouped(GitChanges.parse(porcelain: output))

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
