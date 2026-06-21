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

    /// The `--pretty` format string: full hash, short hash, relative date, author
    /// name, subject — joined by the Unit Separator. Field order is load-bearing: the
    /// two attacker-controllable free-text fields (author name, then subject) come
    /// LAST. Git permits arbitrary bytes — including this separator — in a commit
    /// message and author name, so the separator is NOT guaranteed absent from them;
    /// putting the structured fields (hashes, date) first, and capping the split in
    /// `parse`, is what stops a crafted commit from shifting them and spoofing the
    /// displayed author/date.
    static let prettyFormat = "%H%x1f%h%x1f%ar%x1f%an%x1f%s"

    /// Parse `git log -z` output (NUL-terminated commit records, each holding the
    /// Unit-Separator-joined fields above) into commits.
    static func parse(logZ output: String) -> [GitCommit] {
        var commits: [GitCommit] = []
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            // maxSplits: 4 caps the field count so the trailing subject absorbs any
            // separator bytes a crafted commit smuggled into it, instead of shifting
            // author/date into the wrong column. Keep empty subsequences so a blank
            // field can't shift the others either.
            let fields = record
                .split(separator: fieldSeparator, maxSplits: 4, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 5 else { continue }   // malformed/truncated — skip
            let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty else { continue }
            commits.append(GitCommit(
                hash: hash,
                shortHash: fields[1].trimmingCharacters(in: .whitespacesAndNewlines),
                // Free-text from the commit — strip control/bidi bytes before display.
                subject: fields[4].sanitizedForSingleLineDisplay(),
                author: fields[3].sanitizedForSingleLineDisplay(),
                relativeDate: fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Commits on the current branch's upstream that aren't in HEAD yet — i.e.
    /// what a pull would bring in. Reflects the last fetch (the status sweep and
    /// the Fetch action both update remote-tracking refs), so pair it with a fetch
    /// for live data. Reuses the history popover's format/parser. `.failure` only
    /// when git itself fails; an up-to-date branch returns an empty list. A branch
    /// with no configured upstream is a *normal* state (the row already shows a
    /// "no upstream" badge), so it returns an empty list rather than surfacing git's
    /// "fatal: no upstream configured" as an error. Network-free and lock-free.
    static func incomingCommits(at path: String, limit: Int = 50) -> Result<[GitCommit], CommandError> {
        let res = Shell.run([
            "git", "--no-optional-locks", "-C", path,
            "log", "-n", "\(limit)", "--no-color", "-z",
            "--pretty=format:\(GitLog.prettyFormat)",
            "HEAD..@{upstream}",
        ])
        guard res.ok else {
            let raw = (res.stderr.isEmpty ? res.stdout : res.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // `git log HEAD..@{upstream}` fails with exit 128 when the branch has
            // no upstream. That's not an error condition for the popover — there is
            // simply nothing incoming on an untracked branch — so return an empty
            // list instead of showing a git fatal message.
            if Self.hasNoUpstreamMessage(raw) { return .success([]) }
            return .failure(CommandError(message: raw.isEmpty ? "git log failed" : raw))
        }
        return .success(GitLog.parse(logZ: res.stdout))
    }

    /// True when `raw` is git's "no upstream configured" failure text. Tolerant of
    /// the branch name git interpolates into the message. Matched on the stable
    /// phrase git has used for years (verified against git's actual exit-128
    /// output: `fatal: no upstream configured for branch '<name>'`); detached HEAD
    /// and other `git log` failures use different wording and stay as errors.
    static func hasNoUpstreamMessage(_ raw: String) -> Bool {
        raw.lowercased().contains("no upstream configured")
    }
}
