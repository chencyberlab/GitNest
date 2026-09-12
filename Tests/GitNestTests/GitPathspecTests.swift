import XCTest

@testable import GitNest

final class GitPathspecTests: XCTestCase {
    private let paths = ["[ab].txt", "a.txt", "b.txt", ":(exclude)skip.txt", "plain.txt"]

    func testWorkingDiffTreatsWildcardAndMagicFilenamesLiterally() throws {
        let path = try makeRepo()
        try writeFiles(in: path, prefix: "old")
        try commit(in: path)
        try writeFiles(in: path, prefix: "new")
        let snapshot = try GitHub.workingTreeChanges(at: path).get()

        for name in paths {
            let file = try XCTUnwrap(snapshot.files.first { $0.path == name })
            let diff = try GitHub.workingFileDiff(at: path, file: file, base: snapshot.base).get()
            assertOnlySelectedFile(diff, path: name, rootCommit: false)
        }
    }

    func testRootAndNonRootCommitDiffsTreatFilenamesLiterally() throws {
        let path = try makeRepo()
        for prefix in ["old", "new"] {
            try writeFiles(in: path, prefix: prefix)
            try commit(in: path)
            let hash = try run(["git", "-C", path, "rev-parse", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot = try GitHub.commitSnapshot(at: path, hash: hash).get()
            for name in paths {
                let file = try XCTUnwrap(snapshot.files.first { $0.path == name })
                let diff = try GitHub.commitFileDiff(at: path, snapshot: snapshot, file: file).get()
                assertOnlySelectedFile(diff, path: name, rootCommit: prefix == "old")
            }
        }
    }

    private func assertOnlySelectedFile(
        _ diff: GitFileDiff, path: String, rootCommit: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .text(let hunks) = diff.content else {
            return XCTFail("Expected a patch for \(path), got \(diff.content)", file: file, line: line)
        }
        XCTAssertEqual(diff.additions, 1, path, file: file, line: line)
        XCTAssertEqual(diff.deletions, rootCommit ? 0 : 1, path, file: file, line: line)
        let additions = hunks.flatMap(\.lines).filter { $0.kind == .addition }.map(\.text)
        XCTAssertEqual(additions, ["\(rootCommit ? "old" : "new") \(path)"], file: file, line: line)
    }

    private func makeRepo() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitNestPathspec-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.path
        try run(["git", "-C", path, "init", "-b", "main"])
        try run(["git", "-C", path, "config", "user.name", "Tester"])
        try run(["git", "-C", path, "config", "user.email", "t@example.com"])
        try run(["git", "-C", path, "config", "commit.gpgsign", "false"])
        return path
    }

    private func writeFiles(in path: String, prefix: String) throws {
        for name in paths {
            try "\(prefix) \(name)\n".write(
                toFile: (path as NSString).appendingPathComponent(name),
                atomically: true, encoding: .utf8)
        }
    }

    private func commit(in path: String) throws {
        try run(["git", "-C", path, "add", "-A"])
        try run(["git", "-C", path, "commit", "--no-verify", "-m", "snapshot"])
    }

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let result = Shell.run(args)
        guard result.ok else { throw CommandError(message: result.stderr) }
        return result.stdout
    }
}
