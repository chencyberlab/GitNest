import XCTest
@testable import GitNest

final class GitLogTests: XCTestCase {
    /// Build one commit record the way `git log --pretty=format:…%x1f…` does.
    /// Params read subject/author/date for clarity, but they're emitted in
    /// `GitLog.prettyFormat`'s actual order: hash, short, date, author, subject.
    private func record(_ hash: String, _ short: String, _ subject: String,
                        _ author: String, _ date: String) -> String {
        [hash, short, date, author, subject].joined(separator: "\u{1f}")
    }

    func testParsesMultipleCommits() {
        // `git log --pretty=format: -z` separates commits with NUL and emits NO
        // trailing NUL after the last one — match that exactly.
        let output = [
            record("abc123def456", "abc123d", "Add feature", "Alice", "2 hours ago"),
            record("def456abc789", "def456a", "Fix bug", "Bob", "yesterday"),
        ].joined(separator: "\u{0}")

        let commits = GitLog.parse(logZ: output)

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].hash, "abc123def456")
        XCTAssertEqual(commits[0].shortHash, "abc123d")
        XCTAssertEqual(commits[0].subject, "Add feature")
        XCTAssertEqual(commits[0].author, "Alice")
        XCTAssertEqual(commits[0].relativeDate, "2 hours ago")
        XCTAssertEqual(commits[1].subject, "Fix bug")
        XCTAssertEqual(commits[1].relativeDate, "yesterday")
    }

    func testHandlesSubjectWithSpacesPunctuationAndColons() {
        let output = record("h1", "h1", "feat: add thing (with parens), commas & a colon", "A", "now")
        let commits = GitLog.parse(logZ: output)

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].subject, "feat: add thing (with parens), commas & a colon")
    }

    func testKeepsEmptyFieldsSoLaterFieldsDoNotShift() {
        // An empty author and subject must not collapse and shift the date out of
        // place. Field order is hash, short, date, author, subject.
        let output = "hashx\u{1f}hx\u{1f}just now\u{1f}\u{1f}"
        let commits = GitLog.parse(logZ: output)

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].subject, "")
        XCTAssertEqual(commits[0].author, "")
        XCTAssertEqual(commits[0].relativeDate, "just now")
    }

    /// A crafted commit can smuggle the field separator into its subject to try to
    /// forge the author/date columns. With the free-text subject last and the split
    /// capped, the structured fields stay correct and the injected bytes are stripped
    /// from the displayed subject. (Reproduces the SEC-1 spoof from review round 3.)
    func testCraftedSubjectCannotSpoofAuthorOrDate() {
        let crafted = "Fix bug\u{1f}EvilAuthor\u{1f}just now"
        let output = record("h1abcdef", "h1abcde", crafted, "RealAuthor", "2 days ago")
        let commits = GitLog.parse(logZ: output)

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].author, "RealAuthor", "author column must not be spoofable")
        XCTAssertEqual(commits[0].relativeDate, "2 days ago", "date column must not be spoofable")
        XCTAssertFalse(commits[0].subject.unicodeScalars.contains("\u{1f}"),
                       "injected separator must be stripped from the displayed subject")
        XCTAssertTrue(commits[0].subject.hasPrefix("Fix bug"))
    }

    /// Control and bidirectional-override bytes in commit text are stripped before
    /// display (Trojan-Source / SEC-2), while legitimate text is preserved.
    func testSanitizesControlAndBidiInSubjectAndAuthor() {
        let output = record("h2abcdef", "h2abcde", "Merge\u{202e}txet", "Al\u{7f}ice", "now")
        let commits = GitLog.parse(logZ: output)

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].subject, "Mergetxet", "RTL override removed")
        XCTAssertEqual(commits[0].author, "Alice", "DEL control char removed")
    }

    func testSkipsEmptyAndMalformedRecords() {
        let valid = record("h1", "h1", "ok", "A", "now")
        // A trailing empty record (stray NUL) and a record missing fields are dropped.
        let output = valid + "\u{0}" + "\u{0}" + "incomplete\u{1f}only-two-fields"
        let commits = GitLog.parse(logZ: output)

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].shortHash, "h1")
    }

    func testEmptyOutputYieldsNoCommits() {
        XCTAssertTrue(GitLog.parse(logZ: "").isEmpty)
        XCTAssertTrue(GitLog.parse(logZ: "\u{0}\u{0}").isEmpty)
    }

    func testSkipsRecordWithBlankHash() {
        let output = "\u{1f}\u{1f}subject\u{1f}A\u{1f}now"
        XCTAssertTrue(GitLog.parse(logZ: output).isEmpty)
    }

    // MARK: - No-upstream detection (#10)

    /// `incomingCommits` on a branch with no configured upstream returns an empty
    /// list rather than a git "fatal" error — "no upstream" is a normal state (the
    /// row already badges it), not something to surface as a failure in the popover.
    func testHasNoUpstreamMessageRecognizesGitFatalPhrasings() {
        // The canonical phrasing git interpolates the branch name into.
        XCTAssertTrue(GitHub.hasNoUpstreamMessage("fatal: no upstream configured for branch 'main'"))
        // Case-insensitive, extra whitespace tolerated.
        XCTAssertTrue(GitHub.hasNoUpstreamMessage("  FATAL: No Upstream Configured for branch 'x'  "))
    }

    func testHasNoUpstreamMessageRejectsUnrelatedErrors() {
        XCTAssertFalse(GitHub.hasNoUpstreamMessage("fatal: not a git repository"))
        XCTAssertFalse(GitHub.hasNoUpstreamMessage("fatal: bad revision 'HEAD..@{upstream}'"))
        XCTAssertFalse(GitHub.hasNoUpstreamMessage(""))
    }

    /// End-to-end against a real repo with no upstream: the call must succeed with
    /// an empty list, proving the no-upstream short-circuit fires for `git log`'s
    /// actual exit-128 + fatal output (not just the string detector in isolation).
    func testIncomingCommitsReturnsEmptyForBranchWithNoUpstream() throws {
        try XCTSkipIf(Shell.resolveExecutable("git") == nil, "git not available")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitnest-noupstream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.path
        XCTAssertTrue(Shell.run(["git", "-C", path, "init", "-b", "main"]).ok)
        _ = Shell.run(["git", "-C", path, "config", "user.email", "t@example.com"])
        _ = Shell.run(["git", "-C", path, "config", "user.name", "T"])
        try "hi\n".write(toFile: (path as NSString).appendingPathComponent("f"),
                         atomically: true, encoding: .utf8)
        XCTAssertTrue(Shell.run(["git", "-C", path, "add", "-A"]).ok)
        // --no-verify so a developer's global hook can't fail the setup commit.
        XCTAssertTrue(Shell.run(["git", "-C", path, "commit", "--no-verify", "-m", "c"]).ok)

        switch GitHub.incomingCommits(at: path) {
        case .success(let commits):
            XCTAssertTrue(commits.isEmpty, "a branch with no upstream has nothing incoming — empty, not an error")
        case .failure(let error):
            return XCTFail("no-upstream must not surface as an error: \(error.message)")
        }
    }
}
