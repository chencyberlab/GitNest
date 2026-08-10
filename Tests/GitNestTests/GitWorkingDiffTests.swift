import XCTest

@testable import GitNest

final class GitWorkingDiffTests: XCTestCase {
    func testParsesUnifiedHunksAndTracksBothLineNumberColumns() {
        let patch = """
            diff --git a/work.swift b/work.swift
            index 1111111..2222222 100644
            --- a/work.swift
            +++ b/work.swift
            @@ -1,3 +1,4 @@ func work() {
             one
            -old
            +new
            +extra
             three
            @@ -10 +11 @@ tail
            -tail
            +end
            \\ No newline at end of file

            """

        let diff = GitDiffParser.parse(unifiedPatch: patch)
        XCTAssertEqual(diff.additions, 3)
        XCTAssertEqual(diff.deletions, 2)
        guard case .text(let hunks) = diff.content else {
            return XCTFail("expected text hunks")
        }
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].header, "@@ -1,3 +1,4 @@ func work() {")
        XCTAssertEqual(hunks[0].lines.map(\.oldLineNumber), [1, 2, nil, nil, 3])
        XCTAssertEqual(hunks[0].lines.map(\.newLineNumber), [1, nil, 2, 3, 4])
        XCTAssertEqual(hunks[0].lines.map(\.kind), [.context, .deletion, .addition, .addition, .context])
        XCTAssertEqual(hunks[1].lines.last?.kind, .metadata)
    }

    func testPreservesBlankAddedAndDeletedLines() {
        let patch = "@@ -1 +1 @@\n-\n+\n"
        let diff = GitDiffParser.parse(unifiedPatch: patch)

        guard case .text(let hunks) = diff.content,
            let lines = hunks.first?.lines
        else {
            return XCTFail("expected one text hunk")
        }
        XCTAssertEqual(lines.map(\.text), ["", ""])
        XCTAssertEqual(lines.map(\.kind), [.deletion, .addition])
    }

    func testRecognizesBinaryAndOversizedPatches() {
        let binary = GitDiffParser.parse(unifiedPatch: "Binary files a/photo.png and b/photo.png differ\n")
        XCTAssertEqual(binary.content, .binary)

        let oversized = GitDiffParser.parse(unifiedPatch: "@@ -1 +1 @@\n-old\n+new\n", maxBytes: 8)
        XCTAssertEqual(oversized.content, .tooLarge(limitBytes: 8))
    }

    /// The size guard has to run before the output is split into lines: an
    /// oversized patch must never be materialised as a line array just to discover
    /// it is oversized. Binary detection still wins for real (always tiny) binary
    /// output, wherever the marker appears in it.
    func testDetectsBinaryMarkerAfterTheDiffHeaderAndChecksSizeFirst() {
        let binary = GitDiffParser.parse(
            unifiedPatch: "diff --git a/photo.png b/photo.png\n"
                + "index 1111111..2222222 100644\n"
                + "Binary files a/photo.png and b/photo.png differ\n")
        XCTAssertEqual(binary.content, .binary)

        let oversizedBeforeBinary = GitDiffParser.parse(
            unifiedPatch: "Binary files a/photo.png and b/photo.png differ\n",
            maxBytes: 8)
        XCTAssertEqual(oversizedBeforeBinary.content, .tooLarge(limitBytes: 8))

        // A source line only ever reaches the parser behind a ` `/`+`/`-` marker,
        // so content that looks like the marker must not be mistaken for one.
        let lookalike = GitDiffParser.parse(
            unifiedPatch: "@@ -1 +1 @@\n-Binary files a and b differ\n+GIT binary patch\n")
        guard case .text(let hunks) = lookalike.content else {
            return XCTFail("expected the lookalike content lines to stay text")
        }
        XCTAssertEqual(hunks.first?.lines.map(\.kind), [.deletion, .addition])
    }

    /// Row backgrounds span the widest line in the file, so the measurement must
    /// cover hunk headers too, count wide scalars as two cells, and stop at the cap
    /// instead of walking a pathological line to its end.
    func testMeasuresWidestDisplayLineIncludingHeadersAndWideScalars() {
        let headerIsWidest = GitDiffParser.parse(unifiedPatch: "@@ -1 +1 @@ short\n-ab\n+cd\n")
        XCTAssertEqual(headerIsWidest.maximumDisplayColumns(limit: 500), "@@ -1 +1 @@ short".count)

        XCTAssertEqual(GitFileDiff.displayColumns("\u{4f60}\u{597d}\u{4e16}\u{754c}", limit: 500), 8)
        XCTAssertEqual(GitFileDiff.displayColumns("a\u{1b}b", limit: 500), 2)   // ESC is never rendered
        XCTAssertEqual(GitFileDiff.displayColumns("\ta", limit: 500), 5)        // tab counts generously
        XCTAssertEqual(GitFileDiff.displayColumns(String(repeating: "x", count: 10_000), limit: 40), 40)

        XCTAssertEqual(
            GitFileDiff(additions: 0, deletions: 0, content: .binary).maximumDisplayColumns(limit: 500),
            0)
    }

    func testIgnoresMalformedAndCombinedHunkHeaders() {
        let malformed = "@@ not-a-range @@\n-old\n+new\n@@@ -1 -1 +1 @@@\n"
        let diff = GitDiffParser.parse(unifiedPatch: malformed)
        XCTAssertEqual(diff.content, .noLineChanges)
    }

    /// Paths stay forgiving (fuzzy abbreviations are how the repo search bar
    /// behaves), but changed code matches literally: a 4-letter subsequence hits
    /// nearly every line of source, which would bury real results and exhaust the
    /// match cap before reaching them.
    func testSearchIsFuzzyOnPathsButLiteralOnChangedCode() {
        let source = GitFileChange(path: "Sources/AccountManager.swift", originalPath: nil, status: .modified)
        let readme = GitFileChange(path: "README.md", originalPath: nil, status: .modified)
        let sourceDiff = GitDiffParser.parse(
            unifiedPatch: "@@ -8 +8 @@ refresh\n-oldAccountValue\n+newAccountValue\n")
        let sourceEntry = GitWorkingDiffSearch.indexedFile(source, diff: sourceDiff).entry
        let readmeEntry = GitWorkingDiffSearch.indexedFile(
            readme,
            diff: .init(
                additions: 0,
                deletions: 0,
                content: .noLineChanges)
        ).entry
        let index = GitWorkingDiffSearchIndex(
            files: [sourceEntry, readmeEntry],
            isCodeIndexTruncated: false,
            failedFileCount: 0)

        let fileMatches = GitWorkingDiffSearch.matches(query: "sources/*.sw?ft", in: index)
        XCTAssertEqual(fileMatches.files.map(\.file.path), ["Sources/AccountManager.swift"])
        XCTAssertTrue(fileMatches.code.isEmpty)

        let immediateFileMatches = GitWorkingDiffSearch.pathMatches(
            query: "r*dme.?d",
            files: [source, readme])
        XCTAssertEqual(immediateFileMatches.files.map(\.file.path), ["README.md"])

        let fuzzyPathMatches = GitWorkingDiffSearch.matches(query: "srcacntmgr", in: index)
        XCTAssertEqual(fuzzyPathMatches.files.map(\.file.path), ["Sources/AccountManager.swift"])

        let codeMatches = GitWorkingDiffSearch.matches(query: "newaccount", in: index)
        XCTAssertTrue(codeMatches.files.isEmpty)
        XCTAssertEqual(codeMatches.code.count, 1)
        XCTAssertEqual(codeMatches.code.first?.file.path, "Sources/AccountManager.swift")
        XCTAssertEqual(codeMatches.code.first?.line.kind, .addition)
        XCTAssertEqual(codeMatches.code.first?.line.newLineNumber, 8)
        XCTAssertEqual(codeMatches.code.first?.hunkHeader, "@@ -8 +8 @@ refresh")

        let globCodeMatches = GitWorkingDiffSearch.matches(query: "*account*", in: index)
        XCTAssertEqual(globCodeMatches.code.count, 2)

        // `nacv` is a subsequence of "newAccountValue" but not a substring: the old
        // forgiving semantics matched it, the literal code semantics must not.
        XCTAssertEqual(GitWorkingDiffSearch.matches(query: "nacv", in: index).totalCount, 0)
    }

    func testSearchIndexSkipsMetadataAndHonorsItsLineLimit() {
        let file = GitFileChange(path: "work.swift", originalPath: nil, status: .modified)
        let diff = GitDiffParser.parse(
            unifiedPatch: "@@ -1,2 +1,2 @@\n-old value\n+new value\n\\ No newline at end of file\n")
        let indexed = GitWorkingDiffSearch.indexedFile(file, diff: diff, maximumLines: 1)

        XCTAssertTrue(indexed.isTruncated)
        XCTAssertEqual(indexed.entry.lines.count, 1)
        XCTAssertEqual(indexed.entry.lines.first?.line.kind, .deletion)

        let index = GitWorkingDiffSearchIndex(
            files: [indexed.entry],
            isCodeIndexTruncated: true,
            failedFileCount: 0)
        let metadata = GitWorkingDiffSearch.matches(query: "no newline", in: index)
        XCTAssertEqual(metadata.totalCount, 0)
    }

    func testSearchCountsMatchesBeyondTheDisplayedResultLimit() {
        let file = GitFileChange(path: "work.swift", originalPath: nil, status: .modified)
        let diff = GitDiffParser.parse(
            unifiedPatch: "@@ -1,2 +1,2 @@\n-old value\n+new value\n")
        let entry = GitWorkingDiffSearch.indexedFile(file, diff: diff).entry
        let index = GitWorkingDiffSearchIndex(
            files: [entry],
            isCodeIndexTruncated: false,
            failedFileCount: 0)

        let matches = GitWorkingDiffSearch.matches(
            query: "value",
            in: index,
            maximumFileMatches: 0,
            maximumCodeMatches: 1)
        XCTAssertEqual(matches.totalCount, 2)
        XCTAssertEqual(matches.code.count, 1)
        XCTAssertTrue(matches.isTruncated)
    }

    func testWorkingTreeDiffIncludesTrackedAndUntrackedFiles() throws {
        let path = try makeRepo(withInitialCommit: true)
        try "one\nchanged\n".write(
            toFile: (path as NSString).appendingPathComponent("work.txt"),
            atomically: true,
            encoding: .utf8)
        let nested = (path as NSString).appendingPathComponent("new folder")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try "fresh\n".write(
            toFile: (nested as NSString).appendingPathComponent("fresh file.txt"),
            atomically: true,
            encoding: .utf8)

        guard case .success(let snapshot) = GitHub.workingTreeChanges(at: path) else {
            return XCTFail("workingTreeChanges failed")
        }
        guard case .head(let hash) = snapshot.base else {
            return XCTFail("expected a HEAD comparison")
        }
        XCTAssertFalse(hash.isEmpty)
        XCTAssertEqual(Set(snapshot.files.map(\.path)), ["work.txt", "new folder/fresh file.txt"])

        guard let modified = snapshot.files.first(where: { $0.path == "work.txt" }),
            case .success(let modifiedDiff) = GitHub.workingFileDiff(
                at: path,
                file: modified,
                base: snapshot.base),
            case .text(let modifiedHunks) = modifiedDiff.content
        else {
            return XCTFail("tracked file diff failed")
        }
        XCTAssertTrue(
            modifiedHunks.flatMap(\.lines).contains(where: {
                $0.kind == .addition && $0.text == "changed"
            }))
        XCTAssertTrue(
            modifiedHunks.flatMap(\.lines).contains(where: {
                $0.kind == .deletion && $0.text == "two"
            }))

        guard let untracked = snapshot.files.first(where: { $0.path == "new folder/fresh file.txt" }),
            case .success(let untrackedDiff) = GitHub.workingFileDiff(
                at: path,
                file: untracked,
                base: snapshot.base),
            case .text(let untrackedHunks) = untrackedDiff.content
        else {
            return XCTFail("untracked file diff failed")
        }
        XCTAssertEqual(untrackedDiff.additions, 1)
        XCTAssertTrue(
            untrackedHunks.flatMap(\.lines).contains(where: {
                $0.kind == .addition && $0.text == "fresh"
            }))
    }

    func testUnbornRepositoryComparesWithEmpty() throws {
        let path = try makeRepo(withInitialCommit: false)
        try "first\n".write(
            toFile: (path as NSString).appendingPathComponent("first.txt"),
            atomically: true,
            encoding: .utf8)

        guard case .success(let snapshot) = GitHub.workingTreeChanges(at: path) else {
            return XCTFail("workingTreeChanges failed")
        }
        XCTAssertEqual(snapshot.base, .emptyRepository)
        guard let file = snapshot.files.first,
            case .success(let diff) = GitHub.workingFileDiff(at: path, file: file, base: snapshot.base)
        else {
            return XCTFail("empty-repository diff failed")
        }
        XCTAssertEqual(diff.additions, 1)
        XCTAssertEqual(diff.deletions, 0)
    }

    /// `git status -uall` reports an untracked *nested clone* as one directory
    /// entry. Asking `git diff --no-index` for a patch of it fails with a raw
    /// "Could not access 'sub/null'", so the viewer must recognise it up front.
    func testUntrackedNestedRepositoryIsReportedInsteadOfFailing() throws {
        let path = try makeRepo(withInitialCommit: true)
        let nested = (path as NSString).appendingPathComponent("vendored")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        XCTAssertTrue(Shell.run(["git", "-C", nested, "init", "-b", "main"]).ok)
        try "inner\n".write(
            toFile: (nested as NSString).appendingPathComponent("inner.txt"),
            atomically: true,
            encoding: .utf8)

        guard case .success(let snapshot) = GitHub.workingTreeChanges(at: path) else {
            return XCTFail("workingTreeChanges failed")
        }
        guard let folder = snapshot.files.first(where: { $0.path.hasPrefix("vendored") }) else {
            return XCTFail("expected the nested clone to be listed")
        }
        XCTAssertEqual(folder.path, "vendored/")
        guard case .success(let diff) = GitHub.workingFileDiff(at: path, file: folder, base: snapshot.base) else {
            return XCTFail("a nested clone must not surface as a git failure")
        }
        XCTAssertEqual(diff.content, .unreadableSource(.nestedRepository))
    }

    /// A fifo would make `git diff --no-index` block on a read until the Shell
    /// timeout fires, so non-regular files are refused before git is spawned.
    func testUntrackedNonRegularFileIsRefusedWithoutSpawningGit() throws {
        let path = try makeRepo(withInitialCommit: true)
        let fifo = (path as NSString).appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)

        let file = GitFileChange(path: "pipe", originalPath: nil, status: .untracked)
        guard case .success(let diff) = GitHub.workingFileDiff(at: path, file: file, base: .emptyRepository) else {
            return XCTFail("a fifo must not surface as a git failure")
        }
        XCTAssertEqual(diff.content, .unreadableSource(.notARegularFile))
    }

    /// Symlinks stay diffable — git renders them as a one-line patch of the target.
    func testUntrackedSymlinkStillProducesAPatch() throws {
        let path = try makeRepo(withInitialCommit: true)
        try FileManager.default.createSymbolicLink(
            atPath: (path as NSString).appendingPathComponent("link"),
            withDestinationPath: "work.txt")

        let file = GitFileChange(path: "link", originalPath: nil, status: .untracked)
        guard case .success(let diff) = GitHub.workingFileDiff(at: path, file: file, base: .emptyRepository),
            case .text(let hunks) = diff.content
        else {
            return XCTFail("expected a text patch for the symlink")
        }
        XCTAssertTrue(hunks.flatMap(\.lines).contains { $0.kind == .addition && $0.text == "work.txt" })
    }

    private func makeRepo(withInitialCommit: Bool) throws -> String {
        try XCTSkipIf(Shell.resolveExecutable("git") == nil, "git not available")
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("gitnest-working-diff-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? fileManager.removeItem(at: directory) }
        let path = directory.path

        XCTAssertTrue(Shell.run(["git", "-C", path, "init", "-b", "main"]).ok)
        guard withInitialCommit else { return path }
        _ = Shell.run(["git", "-C", path, "config", "user.email", "t@example.com"])
        _ = Shell.run(["git", "-C", path, "config", "user.name", "Tester"])
        _ = Shell.run(["git", "-C", path, "config", "commit.gpgsign", "false"])
        try "one\ntwo\n".write(
            toFile: (path as NSString).appendingPathComponent("work.txt"),
            atomically: true,
            encoding: .utf8)
        XCTAssertTrue(Shell.run(["git", "-C", path, "add", "-A"]).ok)
        XCTAssertTrue(Shell.run(["git", "-C", path, "commit", "--no-verify", "-m", "base"]).ok)
        return path
    }
}
