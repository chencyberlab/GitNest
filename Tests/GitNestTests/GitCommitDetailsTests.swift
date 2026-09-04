import XCTest

@testable import GitNest

final class GitCommitDetailsTests: XCTestCase {
    private let commitHash = String(repeating: "a", count: 40)
    private let firstParent = String(repeating: "b", count: 40)
    private let secondParent = String(repeating: "c", count: 40)

    func testParsesMetadataIncludingMergeParentsAndMultilineMessage() {
        let output = [
            commitHash,
            "aaaaaaa",
            "2026-09-04T10:00:00+09:30",
            "\(firstParent) \(secondParent)",
            "Alice\u{202e}",
            "Subject\n\nBody\ttext\u{1b}\n",
        ].joined(separator: "\0") + "\0"

        let detail = GitCommitDetails.parse(metadataZ: output)

        XCTAssertEqual(detail?.hash, commitHash)
        XCTAssertEqual(detail?.shortHash, "aaaaaaa")
        XCTAssertEqual(detail?.authoredAt, "2026-09-04T10:00:00+09:30")
        XCTAssertEqual(detail?.parentHashes, [firstParent, secondParent])
        XCTAssertEqual(detail?.author, "Alice")
        XCTAssertEqual(detail?.subject, "Subject")
        XCTAssertEqual(detail?.message, "Subject\n\nBody\ttext")
    }

    func testParsesRootCommitWithEmptyParentField() {
        let output = [commitHash, "aaaaaaa", "now", "", "A", "root"].joined(separator: "\0") + "\0"

        let detail = GitCommitDetails.parse(metadataZ: output)

        XCTAssertEqual(detail?.parentHashes, [])
        XCTAssertEqual(detail?.message, "root")
    }

    func testRejectsMalformedMetadataAndObjectIDs() {
        XCTAssertNil(GitCommitDetails.parse(metadataZ: "too\0short"))
        XCTAssertFalse(GitCommitDetails.isValidObjectID("HEAD"))
        XCTAssertFalse(GitCommitDetails.isValidObjectID(String(repeating: "z", count: 40)))
        XCTAssertTrue(GitCommitDetails.isValidObjectID(commitHash))
        XCTAssertTrue(GitCommitDetails.isValidObjectID(String(repeating: "F", count: 64)))

        let invalidParent = [commitHash, "aaaaaaa", "now", "HEAD", "A", "message"].joined(separator: "\0")
        XCTAssertNil(GitCommitDetails.parse(metadataZ: invalidParent))
    }

    func testParsesChangedFilesIncludingRenameAndUnusualPaths() {
        let output = [
            "M", "Sources/App.swift",
            "A", "new\nfile.txt",
            "D", "old file.txt",
            "T", "mode.txt",
            "R097", "before.txt", "after.txt",
            "C100", "source.txt", "copy.txt",
            "Q", "other.txt",
        ].joined(separator: "\0") + "\0"

        let files = GitCommitDetails.parse(nameStatusZ: output)

        XCTAssertEqual(files.map(\.path), [
            "Sources/App.swift", "new\nfile.txt", "old file.txt", "mode.txt",
            "after.txt", "copy.txt", "other.txt",
        ])
        XCTAssertEqual(files.map(\.originalPath), [nil, nil, nil, nil, "before.txt", "source.txt", nil])
        XCTAssertEqual(files.map(\.status), [
            .modified, .added, .deleted, .modified, .renamed, .renamed, .other("Q"),
        ])
    }

    func testSkipsEmptyAndMalformedChangedFileRecords() {
        XCTAssertTrue(GitCommitDetails.parse(nameStatusZ: "").isEmpty)
        XCTAssertTrue(GitCommitDetails.parse(nameStatusZ: "M\0").isEmpty)
        XCTAssertTrue(GitCommitDetails.parse(nameStatusZ: "R100\0only-old\0").isEmpty)

        let output = "M\0good.txt\0R100\0only-old\0"
        XCTAssertEqual(GitCommitDetails.parse(nameStatusZ: output).map(\.path), ["good.txt"])
    }

    func testDescribesMergeCommitAsAFirstParentComparison() {
        let snapshot = GitCommitSnapshot(
            detail: GitCommitDetail(
                hash: commitHash,
                shortHash: "aaaaaaa",
                authoredAt: "now",
                parentHashes: [firstParent, secondParent],
                author: "Tester",
                message: "Merge"),
            files: [])

        XCTAssertEqual(snapshot.comparisonDescription, "Merge commit · compared with first parent bbbbbbbbbbbb")
    }

    func testLoadsRootCommitAndSelectedFileDiffFromARealRepository() throws {
        try XCTSkipIf(Shell.resolveExecutable("git") == nil, "git not available")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitnest-commit-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.path

        XCTAssertTrue(Shell.run(["git", "-C", path, "init", "-b", "main"]).ok)
        XCTAssertTrue(Shell.run(["git", "-C", path, "config", "user.email", "t@example.com"]).ok)
        XCTAssertTrue(Shell.run(["git", "-C", path, "config", "user.name", "Tester"]).ok)
        XCTAssertTrue(Shell.run(["git", "-C", path, "config", "commit.gpgsign", "false"]).ok)
        try "first\n".write(
            toFile: (path as NSString).appendingPathComponent("hello.txt"),
            atomically: true,
            encoding: .utf8)
        XCTAssertTrue(Shell.run(["git", "-C", path, "add", "-A"]).ok)
        XCTAssertTrue(Shell.run(["git", "-C", path, "commit", "--no-verify", "-m", "Root subject"]).ok)

        let rev = Shell.run(["git", "-C", path, "rev-parse", "HEAD"])
        let rootHash = rev.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .success(let snapshot) = GitHub.commitSnapshot(at: path, hash: rootHash) else {
            return XCTFail("root commit snapshot failed")
        }
        XCTAssertTrue(snapshot.detail.parentHashes.isEmpty)
        XCTAssertEqual(snapshot.detail.subject, "Root subject")
        XCTAssertEqual(snapshot.files.map(\.path), ["hello.txt"])
        XCTAssertEqual(snapshot.files.first?.status, .added)

        guard let file = snapshot.files.first,
            case .success(let diff) = GitHub.commitFileDiff(at: path, snapshot: snapshot, file: file),
            case .text(let hunks) = diff.content
        else {
            return XCTFail("root commit file diff failed")
        }
        XCTAssertEqual(diff.additions, 1)
        XCTAssertEqual(diff.deletions, 0)
        XCTAssertTrue(hunks.flatMap(\.lines).contains { $0.kind == .addition && $0.text == "first" })

        try "second\n".write(
            toFile: (path as NSString).appendingPathComponent("hello.txt"),
            atomically: true,
            encoding: .utf8)
        XCTAssertTrue(Shell.run(["git", "-C", path, "commit", "--no-verify", "-am", "Second subject"]).ok)
        let secondRev = Shell.run(["git", "-C", path, "rev-parse", "HEAD"])
        let secondHash = secondRev.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .success(let secondSnapshot) = GitHub.commitSnapshot(at: path, hash: secondHash) else {
            return XCTFail("non-root commit snapshot failed")
        }
        XCTAssertEqual(secondSnapshot.detail.parentHashes, [rootHash])
        XCTAssertEqual(secondSnapshot.files.map(\.path), ["hello.txt"])
        XCTAssertEqual(secondSnapshot.files.first?.status, .modified)

        guard let secondFile = secondSnapshot.files.first,
            case .success(let secondDiff) = GitHub.commitFileDiff(
                at: path,
                snapshot: secondSnapshot,
                file: secondFile)
        else {
            return XCTFail("non-root commit file diff failed")
        }
        XCTAssertEqual(secondDiff.additions, 1)
        XCTAssertEqual(secondDiff.deletions, 1)
    }

    func testRejectsUntrustedRevisionBeforeRunningGit() {
        guard case .failure(let error) = GitHub.commitSnapshot(at: "/missing", hash: "HEAD") else {
            return XCTFail("untrusted revision should be rejected")
        }
        XCTAssertTrue(error.message.contains("identifier is invalid"))
    }
}
