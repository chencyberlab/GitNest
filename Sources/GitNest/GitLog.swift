import Foundation

/// One commit from `git log`, for the lightweight history popover. Deliberately
/// minimal — this powers a quick "what landed here recently" summary, not a full
/// log viewer. Mirrors GitFileChange/GitChanges: the parser is kept separate from
/// the shell call so it can be unit-tested without a real repo.
struct GitCommit: Identifiable, Sendable {
    let id = UUID()
    let hash: String          // full commit hash
    let shortHash: String     // git's abbreviated hash
    let subject: String       // first line of the message
    let author: String        // author name
    let relativeDate: String  // e.g. "3 days ago"
}

/// Pure parsing for `git log -z --pretty=format:…`, kept separate from the shell
/// call so it can be unit-tested without a real repo.
enum GitLog {
    /// Field separator we ask git to emit between fields of one commit.
    static let fieldSeparator: Character = "\u{1f}"   // ASCII Unit Separator

    /// The `--pretty` format string: full hash, short hash, subject, author name,
    /// relative date — joined by the Unit Separator. Paired with `-z`, git emits a
    /// NUL between commits, so neither a subject containing spaces/commas/quotes nor
    /// a field separator inside text can ever be misread (the separators are control
    /// characters that don't occur in hashes, names, dates, or a subject line).
    static let prettyFormat = "%H%x1f%h%x1f%s%x1f%an%x1f%ar"

    /// Parse `git log -z` output (NUL-terminated commit records, each holding the
    /// Unit-Separator-joined fields above) into commits.
    static func parse(logZ output: String) -> [GitCommit] {
        var commits: [GitCommit] = []
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            // Keep empty subsequences so an empty author/date can't shift later fields.
            let fields = record
                .split(separator: fieldSeparator, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 5 else { continue }   // malformed/truncated — skip
            let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty else { continue }
            commits.append(GitCommit(
                hash: hash,
                shortHash: fields[1].trimmingCharacters(in: .whitespacesAndNewlines),
                subject: fields[2],
                author: fields[3],
                relativeDate: fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return commits
    }
}

extension GitHub {
    /// Recent commits on the current branch, loaded on demand for the history
    /// popover. Returns `.failure` only when git itself fails (not a repo, no commits
    /// yet, git missing, …). Network-free, and never takes `.git/index.lock` so it
    /// can't collide with a concurrent commit/pull.
    static func recentCommits(at path: String, limit: Int = 20) -> Result<[GitCommit], CommandError> {
        let res = Shell.run([
            "git", "--no-optional-locks", "-C", path,
            "log", "-n", "\(limit)", "--no-color", "-z",
            "--pretty=format:\(GitLog.prettyFormat)",
        ])
        guard res.ok else {
            let raw = (res.stderr.isEmpty ? res.stdout : res.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CommandError(message: raw.isEmpty ? "git log failed" : raw))
        }
        return .success(GitLog.parse(logZ: res.stdout))
    }
}
