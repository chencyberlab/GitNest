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

    // MARK: - Edge cases

    func testParseHandlesRenameWithSpacesInPath() {
        // -z keeps the full new path as one token, followed by the original path token.
        let changes = GitChanges.parse(porcelainZ: "R  new/app name.swift\u{0}old/app name.swift\u{0}")

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].status, .renamed)
        XCTAssertEqual(changes[0].path, "new/app name.swift")
        XCTAssertEqual(changes[0].originalPath, "old/app name.swift")
    }

    func testParseHandlesMixedConflictedAndUntracked() {
        let changes = GitChanges.parse(porcelainZ: "UU both.txt\u{0}?? ignored-for-now.md\u{0}AA added.txt\u{0}")

        XCTAssertEqual(changes.map(\.status), [.conflicted, .untracked, .conflicted])
        XCTAssertEqual(changes.map(\.path), ["both.txt", "ignored-for-now.md", "added.txt"])
    }

    func testParseTreatsIgnoredAsOther() {
        // `git status --porcelain` does not show ignored files unless --ignored is passed,
        // but if it ever does we should classify it as .other rather than unknown.
        let changes = GitChanges.parse(porcelainZ: "!! build/output.app\u{0}")

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].status, .other("!!"))
        XCTAssertEqual(changes[0].path, "build/output.app")
    }

    func testParseIgnoresBareStatusCodesWithoutPath() {
        // Malformed output such as just " M" or a stray newline should be skipped.
        let changes = GitChanges.parse(porcelainZ: " M\u{0}?? fine.txt\u{0}")

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].path, "fine.txt")
    }

    func testParseHandlesConsecutiveNULsWithoutDroppingRecords() {
        let changes = GitChanges.parse(porcelainZ: "\u{0} M a.swift\u{0}\u{0}?? b.swift\u{0}")

        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.map(\.path), ["a.swift", "b.swift"])
    }

    func testParseHandlesCopyAsRename() {
        let changes = GitChanges.parse(porcelainZ: "C  copied.txt\u{0}original.txt\u{0}")

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].status, .renamed)
        XCTAssertEqual(changes[0].path, "copied.txt")
        XCTAssertEqual(changes[0].originalPath, "original.txt")
    }

    func testGroupedSortsOtherLast() {
        let groups = GitChanges.grouped(GitChanges.parse(porcelainZ: "!! one\u{0} M two\u{0}?? three\u{0}"))

        XCTAssertEqual(groups.map(\.title), ["Modified", "Untracked", "Other"])
    }
}
