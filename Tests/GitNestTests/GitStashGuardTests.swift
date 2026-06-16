import XCTest
@testable import GitNest

/// Integration tests (real git, temp repo) for the stash *mechanism* the UI relies
/// on for data safety. `GitStashTests` only covers the string parser; the actual
/// protection against dropping/applying the wrong stash is `stashHash(at:index:)`
/// re-validation, which is meaningless without real git. These pin that.
final class GitStashGuardTests: XCTestCase {
    private func makeRepo() throws -> String {
        try XCTSkipIf(Shell.resolveExecutable("git") == nil, "git not available")
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("gitnest-stash-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        let path = dir.path

        XCTAssertTrue(Shell.run(["git", "-C", path, "init", "-b", "main"]).ok)
        _ = Shell.run(["git", "-C", path, "config", "user.email", "t@example.com"])
        _ = Shell.run(["git", "-C", path, "config", "user.name", "Tester"])
        _ = Shell.run(["git", "-C", path, "config", "commit.gpgsign", "false"])

        let file = dir.appendingPathComponent("work.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(Shell.run(["git", "-C", path, "add", "-A"]).ok)
        // --no-verify so a developer's global pre-commit/commit-msg hook can't fail
        // the setup commit and make this test flaky.
        XCTAssertTrue(Shell.run(["git", "-C", path, "commit", "--no-verify", "-m", "base"]).ok)
        return path
    }

    private func write(_ text: String, to path: String) throws {
        let file = (path as NSString).appendingPathComponent("work.txt")
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    func testStashHashTracksEntryAndDetectsAShiftedStack() throws {
        let path = try makeRepo()

        try write("first change\n", to: path)
        XCTAssertTrue(GitHub.stashPush(at: path, message: "first").ok)
        try write("second change\n", to: path)
        XCTAssertTrue(GitHub.stashPush(at: path, message: "second").ok)

        // git pushes onto the top, so index 0 is the most recent ("second").
        guard case .success(let entries) = GitHub.stashList(at: path) else {
            return XCTFail("stashList failed")
        }
        XCTAssertEqual(entries.count, 2)
        let h2 = entries[0].hash   // index 0 = "second"
        let h1 = entries[1].hash   // index 1 = "first"
        XCTAssertNotEqual(h1, h2)

        // stashHash resolves the same SHA the list reported for each live index —
        // this is the value the popover captures as `expectedHash`.
        XCTAssertEqual(GitHub.stashHash(at: path, index: 0), h2)
        XCTAssertEqual(GitHub.stashHash(at: path, index: 1), h1)

        // The user armed an action on index 0 (expecting H2). The stack then shifts
        // out-of-band (an external drop of stash@{0}). Re-reading index 0 now yields
        // H1, so the coordinator's `stashHash(0) == expectedHash` guard refuses —
        // it can never apply/drop the wrong stash after a shift.
        let expectedForIndex0 = h2
        XCTAssertTrue(GitHub.stashDrop(at: path, index: 0).ok)
        XCTAssertEqual(GitHub.stashHash(at: path, index: 0), h1)
        XCTAssertNotEqual(GitHub.stashHash(at: path, index: 0), expectedForIndex0)

        // Only one stash remains; an out-of-range index resolves to nil (the guard
        // treats nil as a mismatch and refuses).
        XCTAssertNil(GitHub.stashHash(at: path, index: 5))
    }

    func testStashCountAndCleanTreeNoOp() throws {
        let path = try makeRepo()

        XCTAssertEqual(GitHub.stashCount(at: path), 0)
        // Pushing a clean tree is a no-op: git exits 0 with "No local changes to
        // save" and the stack stays empty.
        let res = GitHub.stashPush(at: path)
        XCTAssertTrue(res.ok)
        XCTAssertEqual(GitHub.stashCount(at: path), 0)

        try write("dirty\n", to: path)
        XCTAssertTrue(GitHub.stashPush(at: path, message: "wip").ok)
        XCTAssertEqual(GitHub.stashCount(at: path), 1)
    }

    func testPopRestoresAndRemovesWhileApplyKeeps() throws {
        let path = try makeRepo()
        try write("change\n", to: path)
        XCTAssertTrue(GitHub.stashPush(at: path, message: "wip").ok)
        XCTAssertEqual(GitHub.stashCount(at: path), 1)

        // apply restores but keeps the entry on the stack.
        XCTAssertTrue(GitHub.stashApply(at: path, index: 0).ok)
        XCTAssertEqual(GitHub.stashCount(at: path), 1)

        // Reset the working tree, then pop: restores AND removes the entry.
        XCTAssertTrue(Shell.run(["git", "-C", path, "checkout", "--", "."]).ok)
        XCTAssertTrue(GitHub.stashPop(at: path, index: 0).ok)
        XCTAssertEqual(GitHub.stashCount(at: path), 0)
    }
}
