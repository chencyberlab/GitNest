import Foundation

/// One entry from `git stash list`, for the stash-management popover. Deliberately
/// minimal — the selector (`stash@{N}`) to act on and the description git shows for
/// it. Mirrors GitCommit/GitFileChange: the parser is kept separate from the shell
/// call so it can be unit-tested without a real repo.
struct GitStashEntry: Identifiable, Sendable {
    let id = UUID()
    let index: Int        // the N in stash@{N}; what apply/pop/drop act on
    let selector: String  // "stash@{N}" exactly as git reported it
    let subject: String   // git's description, e.g. "WIP on main: 1a2b3c4 Fix bug"
}

/// Pure parsing for `git stash list -z --format=…`, kept separate from the shell
/// call so it can be unit-tested without a real repo. Mirrors GitLog.
enum GitStash {
    /// Field separator we ask git to emit between the selector and the subject.
    static let fieldSeparator: Character = "\u{1f}"   // ASCII Unit Separator

    /// The `--format` string: the shortened reflog selector (`stash@{N}`) and the
    /// reflog subject (the human description), joined by the Unit Separator. Paired
    /// with `-z`, git NUL-separates entries, so neither a subject containing spaces,
    /// commas, or quotes, nor the field separator inside text, can ever be misread.
    static let listFormat = "%gd%x1f%gs"

    /// Parse `git stash list -z` output (NUL-separated entries, each the
    /// Unit-Separator-joined selector + subject) into entries. Tolerant of git's
    /// trailing NUL after the last entry.
    static func parse(listZ output: String) -> [GitStashEntry] {
        var entries: [GitStashEntry] = []
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            // Keep empty subsequences so an empty subject can't shift the selector.
            let fields = record
                .split(separator: fieldSeparator, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 2 else { continue }   // malformed/truncated — skip
            let selector = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = index(from: selector) else { continue }
            entries.append(GitStashEntry(index: index, selector: selector, subject: fields[1]))
        }
        return entries
    }

    /// Extract the N from a `stash@{N}` selector.
    static func index(from selector: String) -> Int? {
        guard let open = selector.firstIndex(of: "{"),
              let close = selector.firstIndex(of: "}"),
              open < close else { return nil }
        return Int(selector[selector.index(after: open)..<close])
    }
}

extension GitHub {
    /// All stash entries for a cloned repo, loaded on demand for the stash popover.
    /// `.success([])` for a repo with no stashes; `.failure` only when git fails.
    /// Network-free and never takes `.git/index.lock`.
    static func stashList(at path: String) -> Result<[GitStashEntry], CommandError> {
        let res = Shell.run([
            "git", "--no-optional-locks", "-C", path,
            "stash", "list", "-z", "--format=\(GitStash.listFormat)",
        ])
        guard res.ok else {
            let raw = (res.stderr.isEmpty ? res.stdout : res.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CommandError(message: raw.isEmpty ? "git stash list failed" : raw))
        }
        return .success(GitStash.parse(listZ: res.stdout))
    }

    /// Cheap stash count for the status sweep's badge — just the entry selectors,
    /// no subjects. Read-only and lock-free; returns 0 on any error so a stash probe
    /// can never fail a status refresh.
    static func stashCount(at path: String) -> Int {
        let res = Shell.run([
            "git", "--no-optional-locks", "-C", path,
            "stash", "list", "-z", "--format=%gd",
        ])
        guard res.ok else { return 0 }
        return res.stdout.split(separator: "\0", omittingEmptySubsequences: true).count
    }

    /// Save the working tree's changes (including untracked, so it matches what the
    /// row's change badge counts) onto the stash stack. Exits 0 with "No local
    /// changes to save" when the tree is clean — callers should check for that.
    static func stashPush(at path: String) -> ShellResult {
        Shell.run(["git", "-C", path, "stash", "push", "--include-untracked"])
    }

    /// Restore a stash onto the working tree, keeping it on the stack.
    static func stashApply(at path: String, index: Int) -> ShellResult {
        Shell.run(["git", "-C", path, "stash", "apply", "stash@{\(index)}"])
    }

    /// Restore a stash and remove it from the stack — but only on a clean apply.
    /// Git keeps the stash if applying conflicts, so a failed pop never loses work.
    static func stashPop(at path: String, index: Int) -> ShellResult {
        Shell.run(["git", "-C", path, "stash", "pop", "stash@{\(index)}"])
    }

    /// Discard a stash without restoring it. Destructive and not Trash-recoverable —
    /// callers must confirm first.
    static func stashDrop(at path: String, index: Int) -> ShellResult {
        Shell.run(["git", "-C", path, "stash", "drop", "stash@{\(index)}"])
    }
}
