import Foundation

/// Stable routing data for one working-diff window. The local path is captured
/// when the user opens the window so switching accounts in the main window cannot
/// silently redirect an already-open diff to another account's clone.
struct WorkingDiffTarget: Codable, Hashable, Sendable {
    let repoName: String
    let nameWithOwner: String
    let accountAlias: String
    let localPath: String

    var id: String { "\(accountAlias)|\(nameWithOwner)|\(localPath)" }
}

/// The immutable comparison base captured when the diff window refreshes.
enum GitDiffBase: Equatable, Sendable {
    case head(String)
    case emptyRepository

    var displayName: String {
        switch self {
        case .head(let hash): return "HEAD \(hash.prefix(12))"
        case .emptyRepository: return "an empty repository"
        }
    }
}

/// The changed-file inventory and exact commit it should be compared against.
struct GitWorkingTreeSnapshot: Sendable {
    let base: GitDiffBase
    let files: [GitFileChange]
}

enum GitDiffLineKind: Equatable, Sendable {
    case context
    case addition
    case deletion
    case metadata
}

/// One display line from a unified diff. Added/deleted lines intentionally leave
/// the absent side's number nil, matching GitHub's two-number-column presentation.
struct GitDiffLine: Identifiable, Equatable, Sendable {
    let id: Int
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let kind: GitDiffLineKind
    let text: String
}

struct GitDiffHunk: Identifiable, Equatable, Sendable {
    let id: Int
    let header: String
    let lines: [GitDiffLine]
}

enum GitFileDiffContent: Equatable, Sendable {
    case text([GitDiffHunk])
    case binary
    case noLineChanges
    case tooLarge(limitBytes: Int)
    /// `git status` reports an untracked *folder* as a single entry (with a
    /// trailing slash) when it can't look inside — a nested clone or submodule.
    /// There is no patch to render for it, and asking git for one fails with a
    /// confusing "Could not access" error, so it gets its own explained state.
    case unreadableSource(UnreadableDiffSource)
}

enum UnreadableDiffSource: Equatable, Sendable {
    case nestedRepository
    case notARegularFile

    var title: String {
        switch self {
        case .nestedRepository: return "Untracked folder"
        case .notARegularFile: return "Not a regular file"
        }
    }

    var detail: String {
        switch self {
        case .nestedRepository:
            return """
                Git reports this as one untracked folder because it contains its own repository, \
                so there are no individual files to diff. Add it as a submodule, or open it as its \
                own repo, to see its changes.
                """
        case .notARegularFile:
            return "Only regular files and symlinks can be shown as a line-by-line diff."
        }
    }
}

struct GitFileDiff: Equatable, Sendable {
    let additions: Int
    let deletions: Int
    let content: GitFileDiffContent
}

extension GitFileDiff {
    /// Width of the widest line in the patch, in monospaced character cells.
    ///
    /// The viewer sizes *every* row to this so the added/removed tint spans the
    /// full scrollable width: rows sized to their own content leave ragged stripes
    /// as soon as one line is wider than the window. Measured once per loaded file,
    /// never per render. Wide (CJK/emoji) scalars count as two cells, which is what
    /// a monospaced font actually advances for them.
    func maximumDisplayColumns(limit: Int) -> Int {
        guard case .text(let hunks) = content else { return 0 }
        var widest = 0
        for hunk in hunks {
            widest = max(widest, Self.displayColumns(hunk.header, limit: limit))
            for line in hunk.lines {
                widest = max(widest, Self.displayColumns(line.text, limit: limit))
                if widest >= limit { return limit }
            }
        }
        return widest
    }

    /// Approximate, and deliberately biased *up*: over-measuring only adds trailing
    /// empty space to every row equally, while under-measuring one row makes it
    /// stick out past the others — the exact raggedness this exists to prevent.
    static func displayColumns(_ text: String, limit: Int) -> Int {
        var columns = 0
        for scalar in text.unicodeScalars {
            // Control/format scalars are stripped before rendering (see
            // `sanitizedForCodeLineDisplay`), so they claim no width here either.
            if CharacterSet.controlCharacters.contains(scalar) {
                columns += scalar == "\t" ? tabColumns : 0
            } else {
                columns += scalar.value >= 0x1100 ? 2 : 1
            }
            if columns >= limit { return limit }
        }
        return columns
    }

    /// Cells a hard tab is assumed to advance. SwiftUI picks its own tab stop, so
    /// this is a generous guess in line with the upward bias above.
    private static let tabColumns = 4
}

extension GitFileChange {
    /// A stable key for one path within a captured snapshot. `GitFileChange.id` is
    /// intentionally ephemeral, so it cannot coordinate selection, cached patches,
    /// and search results that all refer to the same rename.
    var workingDiffKey: String {
        "\(originalPath ?? "")\u{0}\(path)"
    }
}

struct GitWorkingDiffSearchLine: Sendable {
    let hunkHeader: String
    let line: GitDiffLine
    let searchableHaystack: String
}

struct GitWorkingDiffSearchFile: Sendable {
    let file: GitFileChange
    let diff: GitFileDiff?
    let searchablePaths: [String]
    let lines: [GitWorkingDiffSearchLine]
}

/// An on-demand, bounded index of the exact patches captured by one diff-window
/// refresh. Every path stays searchable even when the code-line safety cap is hit.
struct GitWorkingDiffSearchIndex: Sendable {
    let files: [GitWorkingDiffSearchFile]
    let isCodeIndexTruncated: Bool
    let failedFileCount: Int

    func entry(for fileKey: String) -> GitWorkingDiffSearchFile? {
        files.first { $0.file.workingDiffKey == fileKey }
    }
}

struct GitWorkingDiffFileMatch: Identifiable, Sendable {
    let file: GitFileChange
    var id: String { file.workingDiffKey }
}

struct GitWorkingDiffCodeMatch: Identifiable, Sendable {
    let file: GitFileChange
    let hunkHeader: String
    let line: GitDiffLine

    var id: String { "\(file.workingDiffKey)\u{0}\(line.id)" }
}

struct GitWorkingDiffSearchMatches: Sendable {
    let files: [GitWorkingDiffFileMatch]
    let code: [GitWorkingDiffCodeMatch]
    let totalCount: Int

    static let empty = GitWorkingDiffSearchMatches(files: [], code: [], totalCount: 0)

    var isTruncated: Bool { totalCount > files.count + code.count }
}

/// Pure indexing and matching for the working-diff search UI. Matching reuses the
/// repo-search semantics — substrings, `*`/`?` globs, and whitespace-separated terms
/// that must all match one result — with one deliberate split: file *paths* also
/// match fuzzily (`gwd` → `GitWorkingDiff.swift`), changed *code* does not. A fuzzy
/// subsequence matches almost every line of code, which would bury the real hits
/// under noise and exhaust the match cap before reaching them.
enum GitWorkingDiffSearch {
    static let maximumIndexedFiles = 250
    static let maximumIndexedLines = 50_000
    static let maximumIndexedPatchBytes = 32 * 1024 * 1024
    static let maximumFileMatches = 80
    static let maximumCodeMatches = 160

    static func patchByteCount(_ diff: GitFileDiff) -> Int {
        guard case .text(let hunks) = diff.content else { return 0 }
        return hunks.reduce(0) { hunkBytes, hunk in
            hunkBytes + hunk.header.utf8.count
                + hunk.lines.reduce(0) { $0 + $1.text.utf8.count + 1 }
        }
    }

    static func indexedFile(
        _ file: GitFileChange,
        diff: GitFileDiff?,
        maximumLines: Int = maximumIndexedLines
    ) -> (entry: GitWorkingDiffSearchFile, isTruncated: Bool) {
        var searchableLines: [GitWorkingDiffSearchLine] = []
        var totalSearchableLines = 0
        if let diff, case .text(let hunks) = diff.content {
            for hunk in hunks {
                for line in hunk.lines where line.kind != .metadata {
                    totalSearchableLines += 1
                    guard searchableLines.count < maximumLines else { continue }
                    searchableLines.append(
                        GitWorkingDiffSearchLine(
                            hunkHeader: hunk.header,
                            line: line,
                            searchableHaystack: line.text.lowercased()))
                }
            }
        }
        let paths = [file.path, file.originalPath].compactMap { $0?.lowercased() }
        return (
            GitWorkingDiffSearchFile(
                file: file,
                diff: diff,
                searchablePaths: paths,
                lines: searchableLines),
            totalSearchableLines > searchableLines.count
        )
    }

    static func matches(
        query: String,
        in index: GitWorkingDiffSearchIndex,
        maximumFileMatches: Int = maximumFileMatches,
        maximumCodeMatches: Int = maximumCodeMatches
    ) -> GitWorkingDiffSearchMatches {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }

        // Compiled once for the whole corpus: this loop runs over every indexed
        // line (tens of thousands), and re-splitting the query per line was the
        // dominant cost of a keystroke.
        let compiled = WildcardMatcher.compile(query)
        var files: [GitWorkingDiffFileMatch] = []
        var code: [GitWorkingDiffCodeMatch] = []
        var totalCount = 0
        for entry in index.files {
            if WildcardMatcher.matches(compiled, haystacks: entry.searchablePaths) {
                totalCount += 1
                if files.count < maximumFileMatches {
                    files.append(GitWorkingDiffFileMatch(file: entry.file))
                }
            }
            for indexedLine in entry.lines
            where WildcardMatcher.matches(
                compiled,
                haystacks: [indexedLine.searchableHaystack],
                strictness: .literal)
            {
                totalCount += 1
                if code.count < maximumCodeMatches {
                    code.append(
                        GitWorkingDiffCodeMatch(
                            file: entry.file,
                            hunkHeader: indexedLine.hunkHeader,
                            line: indexedLine.line))
                }
            }
        }
        return GitWorkingDiffSearchMatches(files: files, code: code, totalCount: totalCount)
    }

    static func pathMatches(
        query: String,
        files: [GitFileChange],
        maximumMatches: Int = maximumFileMatches
    ) -> GitWorkingDiffSearchMatches {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        let compiled = WildcardMatcher.compile(query)
        var matches: [GitWorkingDiffFileMatch] = []
        var totalCount = 0
        for file in files {
            let paths = [file.path, file.originalPath].compactMap { $0?.lowercased() }
            guard WildcardMatcher.matches(compiled, haystacks: paths) else { continue }
            totalCount += 1
            if matches.count < maximumMatches {
                matches.append(GitWorkingDiffFileMatch(file: file))
            }
        }
        return GitWorkingDiffSearchMatches(files: matches, code: [], totalCount: totalCount)
    }
}

/// Pure parser for standard two-way unified diff hunks. File headers are ignored:
/// the filename comes from `git status -z`, which is unambiguous even when a path
/// contains tabs, newlines, quotes, or Git's human-formatted ` -> ` marker.
enum GitDiffParser {
    static let defaultMaxPatchBytes = 12 * 1024 * 1024

    static func parse(
        unifiedPatch output: String,
        maxBytes: Int = defaultMaxPatchBytes
    ) -> GitFileDiff {
        // Size first: an oversized patch must not be split into a line array at all,
        // and the binary marker is scanned inside the single pass below rather than
        // in a second full-output split. (Without `--binary`, git's binary output is
        // a one-line "Binary files … differ", so it can never exceed the limit.)
        guard output.utf8.count <= maxBytes else {
            return GitFileDiff(additions: 0, deletions: 0, content: .tooLarge(limitBytes: maxBytes))
        }

        var rawLines = output.components(separatedBy: "\n")
        if output.hasSuffix("\n"), rawLines.last?.isEmpty == true {
            rawLines.removeLast()
        }

        var hunks: [GitDiffHunk] = []
        var currentHeader: String?
        var currentLines: [GitDiffLine] = []
        var oldLineNumber = 0
        var newLineNumber = 0
        var nextLineID = 0

        func flushHunk() {
            guard let header = currentHeader else { return }
            hunks.append(GitDiffHunk(id: hunks.count, header: header, lines: currentLines))
            currentHeader = nil
            currentLines = []
        }

        for rawLine in rawLines {
            // Only git's own markers sit at column 0 unprefixed — every line of file
            // content carries a ` `/`+`/`-` marker — so this can't false-positive on
            // a source line that happens to start with "Binary files ".
            if rawLine.hasPrefix("Binary files ") || rawLine == "GIT binary patch" {
                return GitFileDiff(additions: 0, deletions: 0, content: .binary)
            }
            if let starts = hunkStarts(rawLine) {
                flushHunk()
                currentHeader = rawLine
                oldLineNumber = starts.old
                newLineNumber = starts.new
                continue
            }
            if rawLine.hasPrefix("diff --git ") {
                flushHunk()
                continue
            }
            guard currentHeader != nil, let marker = rawLine.first else { continue }

            let line: GitDiffLine
            switch marker {
            case " ":
                line = GitDiffLine(
                    id: nextLineID,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: newLineNumber,
                    kind: .context,
                    text: String(rawLine.dropFirst()))
                oldLineNumber += 1
                newLineNumber += 1
            case "+":
                line = GitDiffLine(
                    id: nextLineID,
                    oldLineNumber: nil,
                    newLineNumber: newLineNumber,
                    kind: .addition,
                    text: String(rawLine.dropFirst()))
                newLineNumber += 1
            case "-":
                line = GitDiffLine(
                    id: nextLineID,
                    oldLineNumber: oldLineNumber,
                    newLineNumber: nil,
                    kind: .deletion,
                    text: String(rawLine.dropFirst()))
                oldLineNumber += 1
            case "\\":
                line = GitDiffLine(
                    id: nextLineID,
                    oldLineNumber: nil,
                    newLineNumber: nil,
                    kind: .metadata,
                    text: rawLine)
            default:
                line = GitDiffLine(
                    id: nextLineID,
                    oldLineNumber: nil,
                    newLineNumber: nil,
                    kind: .metadata,
                    text: rawLine)
            }
            nextLineID += 1
            currentLines.append(line)
        }
        flushHunk()

        guard !hunks.isEmpty else {
            return GitFileDiff(additions: 0, deletions: 0, content: .noLineChanges)
        }
        let additions = hunks.reduce(0) { count, hunk in
            count + hunk.lines.filter { $0.kind == .addition }.count
        }
        let deletions = hunks.reduce(0) { count, hunk in
            count + hunk.lines.filter { $0.kind == .deletion }.count
        }
        return GitFileDiff(additions: additions, deletions: deletions, content: .text(hunks))
    }

    private static func hunkStarts(_ header: String) -> (old: Int, new: Int)? {
        guard header.hasPrefix("@@ ") else { return nil }
        let fields = header.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4,
            fields[0] == "@@",
            let old = rangeStart(fields[1], marker: "-"),
            let new = rangeStart(fields[2], marker: "+")
        else { return nil }
        return (old, new)
    }

    private static func rangeStart(_ field: Substring, marker: Character) -> Int? {
        guard field.first == marker else { return nil }
        let number = field.dropFirst().prefix { $0 != "," }
        return Int(number)
    }
}

extension GitHub {
    /// Load the working-tree inventory with every untracked file expanded. The
    /// regular 10-second status scan deliberately uses Git's cheaper directory-
    /// collapsed default; the full inventory is only paid for on demand here.
    static func workingTreeChanges(at path: String) -> Result<GitWorkingTreeSnapshot, CommandError> {
        let head = Shell.run([
            "git", "--no-optional-locks", "-C", path,
            "rev-parse", "--verify", "HEAD",
        ])
        let base: GitDiffBase
        if head.ok {
            let hash = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty else {
                return .failure(CommandError(message: "git returned an empty HEAD commit"))
            }
            base = .head(hash)
        } else {
            // An unborn branch has no HEAD yet. `git status` below is the authority
            // that this is still a valid repository; compare its files with empty.
            base = .emptyRepository
        }

        let status = Shell.run([
            "git", "--no-optional-locks", "-C", path,
            "status", "--porcelain=v1", "-z", "--untracked-files=all",
        ])
        guard status.ok else {
            return .failure(CommandError(message: diffError(status, fallback: "git status failed")))
        }
        return .success(GitWorkingTreeSnapshot(base: base, files: GitChanges.parse(porcelainZ: status.stdout)))
    }

    /// Diff one selected file against the snapshot's exact commit. Loading files
    /// individually keeps a repository-wide change from allocating/rendering one
    /// enormous patch and makes switching files responsive in the native window.
    static func workingFileDiff(
        at path: String,
        file: GitFileChange,
        base: GitDiffBase
    ) -> Result<GitFileDiff, CommandError> {
        if let unreadable = unreadableWorkingDiffSource(at: path, file: file) {
            return .success(GitFileDiff(additions: 0, deletions: 0, content: .unreadableSource(unreadable)))
        }

        let maxSourceBytes = 8 * 1024 * 1024
        if workingDiffSourceTooLarge(at: path, file: file, base: base, limit: maxSourceBytes) {
            return .success(
                GitFileDiff(
                    additions: 0,
                    deletions: 0,
                    content: .tooLarge(limitBytes: maxSourceBytes)))
        }

        let comparesWithEmpty = file.status == .untracked || base == .emptyRepository
        var args = [
            "git", "--no-optional-locks", "-C", path,
            "diff", "--no-ext-diff", "--no-color", "--no-textconv", "--unified=3",
        ]
        if comparesWithEmpty {
            args.append(contentsOf: ["--no-index", "--", "/dev/null", file.path])
        } else if case .head(let revision) = base {
            args.append("--find-renames")
            args.append(revision)
            args.append("--")
            if let originalPath = file.originalPath {
                args.append(originalPath)
            }
            args.append(file.path)
        }

        let result = Shell.run(args)
        let accepted =
            comparesWithEmpty
            ? (result.exitCode == 0 || (result.exitCode == 1 && !result.stdout.isEmpty))
            : result.ok
        guard accepted else {
            return .failure(CommandError(message: diffError(result, fallback: "git diff failed")))
        }
        return .success(GitDiffParser.parse(unifiedPatch: result.stdout))
    }

    /// Reject sources `git diff` can't turn into a patch, *before* spawning it.
    /// An untracked nested clone arrives as `?? sub/` and would make `--no-index`
    /// fail with "Could not access 'sub/null'"; a fifo/device would make it block
    /// on a read until the Shell timeout fires. Both are reported as explained
    /// states instead. Tracked entries are never affected — git only reports a
    /// directory-shaped path for untracked content.
    private static func unreadableWorkingDiffSource(
        at repoPath: String,
        file: GitFileChange
    ) -> UnreadableDiffSource? {
        guard file.status == .untracked else { return nil }
        if file.path.hasSuffix("/") { return .nestedRepository }
        let fullPath = (repoPath as NSString).appendingPathComponent(file.path)
        guard let type = try? FileManager.default.attributesOfItem(atPath: fullPath)[.type] as? FileAttributeType
        else { return nil }
        switch type {
        case .typeRegular, .typeSymbolicLink: return nil
        case .typeDirectory: return .nestedRepository
        default: return .notARegularFile
        }
    }

    private static func workingDiffSourceTooLarge(
        at repoPath: String,
        file: GitFileChange,
        base: GitDiffBase,
        limit: Int
    ) -> Bool {
        let currentPath = (repoPath as NSString).appendingPathComponent(file.path)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: currentPath),
            let size = attributes[.size] as? NSNumber,
            size.int64Value > Int64(limit)
        {
            return true
        }

        guard case .head(let revision) = base else { return false }
        let oldPath = file.originalPath ?? file.path
        let size = Shell.run([
            "git", "--no-optional-locks", "-C", repoPath,
            "cat-file", "-s", "\(revision):\(oldPath)",
        ])
        guard size.ok,
            let bytes = Int64(size.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return bytes > Int64(limit)
    }

    private static func diffError(_ result: ShellResult, fallback: String) -> String {
        let raw = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? fallback : raw
    }
}
