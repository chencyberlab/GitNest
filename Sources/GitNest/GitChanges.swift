import Foundation

/// One changed file from `git status --porcelain`, classified into a coarse group.
/// Lightweight on purpose — this powers the quick summary popover, not a diff view.
struct GitFileChange: Identifiable, Sendable {
    let id = UUID()
    let path: String           // for renames/copies this is the new path
    let originalPath: String?  // the old path, only set for renames/copies
    let status: GitChangeStatus
}

/// Coarse status groups for the summary. `.other` keeps the raw two-letter code
/// so unusual states aren't silently dropped.
enum GitChangeStatus: Equatable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case untracked
    case conflicted
    case other(String)

    /// Heading shown for the group this status belongs to.
    var title: String {
        switch self {
        case .modified:   return "Modified"
        case .added:      return "Added"
        case .deleted:    return "Deleted"
        case .renamed:    return "Renamed"
        case .untracked:  return "Untracked"
        case .conflicted: return "Conflicted"
        case .other:      return "Other"
        }
    }

    /// Stable display order for the groups (matches the prompt's recommendation).
    var sortOrder: Int {
        switch self {
        case .modified:   return 0
        case .added:      return 1
        case .deleted:    return 2
        case .renamed:    return 3
        case .untracked:  return 4
        case .conflicted: return 5
        case .other:      return 6
        }
    }
}

/// A status group with its files, ready to render as one section in the summary.
struct GitChangeGroup: Identifiable {
    let status: GitChangeStatus
    let files: [GitFileChange]
    var id: String { status.title }
    var title: String { status.title }
}

/// Pure parsing/grouping for `git status --porcelain`, kept separate from the
/// shell call so it can be unit-tested without a real repo.
enum GitChanges {
    /// Parse `git status --porcelain` (v1) output into classified file changes.
    /// Handles `XY path` lines and rename/copy `XY old -> new` lines, and strips
    /// the surrounding quotes git adds for paths with unusual characters.
    static func parse(porcelain output: String) -> [GitFileChange] {
        var changes: [GitFileChange] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            // A valid entry is at least "XY p" — two status chars, a space, a path.
            guard line.count > 3 else { continue }
            let chars = Array(line)
            let status = classify(chars[0], chars[1])
            let rest = String(line.dropFirst(3))

            if let arrow = rest.range(of: " -> ") {
                let original = unquote(String(rest[..<arrow.lowerBound]))
                let path = unquote(String(rest[arrow.upperBound...]))
                changes.append(GitFileChange(path: path, originalPath: original, status: status))
            } else {
                changes.append(GitFileChange(path: unquote(rest), originalPath: nil, status: status))
            }
        }
        return changes
    }

    /// Group changes by status and order both the groups and the files within them.
    static func grouped(_ files: [GitFileChange]) -> [GitChangeGroup] {
        Dictionary(grouping: files, by: { $0.status.title })
            .values
            .map { items in
                let sorted = items.sorted {
                    $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
                }
                // All items in a title-group share a group; `.other` codes collapse
                // under one "Other" heading, so any representative status is fine.
                return GitChangeGroup(status: items[0].status, files: sorted)
            }
            .sorted { $0.status.sortOrder < $1.status.sortOrder }
    }

    /// Map a porcelain XY status pair to a coarse group. Order matters: untracked
    /// and unmerged (conflicted) are checked before the single-sided states.
    static func classify(_ x: Character, _ y: Character) -> GitChangeStatus {
        if x == "?" && y == "?" { return .untracked }
        if x == "!" && y == "!" { return .other("!!") }   // ignored (only if explicitly asked for)
        // Unmerged paths: any U, plus AA (both added) and DD (both deleted).
        if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") {
            return .conflicted
        }
        if x == "R" || y == "R" || x == "C" || y == "C" { return .renamed }
        if x == "A" || y == "A" { return .added }
        if x == "D" || y == "D" { return .deleted }
        if x == "M" || y == "M" || x == "T" || y == "T" { return .modified }
        return .other("\(x)\(y)")
    }

    /// Strip the surrounding quotes and undo the basic C-style escapes git uses
    /// when a path contains unusual characters. Plain paths pass through unchanged.
    private static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        let inner = raw.dropFirst().dropLast()
        var result = ""
        var iterator = inner.makeIterator()
        while let c = iterator.next() {
            guard c == "\\" else { result.append(c); continue }
            switch iterator.next() {
            case "n":  result.append("\n")
            case "t":  result.append("\t")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case let other?: result.append(other)
            case nil: break
            }
        }
        return result
    }
}

extension GitHub {
    /// Detailed list of changed files for a cloned repo, loaded on demand for the
    /// summary popover. Returns `.success([])` for a clean tree, and `.failure`
    /// only when git itself fails (not a repo, git missing, etc.). Network-free.
    static func changedFiles(at path: String) -> Result<[GitFileChange], GitHubError> {
        // Mirror status(at:): never take .git/index.lock from this read. Disable
        // path quoting so non-ASCII names come back readable.
        let res = Shell.run([
            "git", "--no-optional-locks", "-C", path,
            "-c", "core.quotePath=false",
            "status", "--porcelain"
        ])
        guard res.ok else {
            let raw = (res.stderr.isEmpty ? res.stdout : res.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GitHubError(message: raw.isEmpty ? "git status failed" : raw))
        }
        return .success(GitChanges.parse(porcelain: res.stdout))
    }
}
