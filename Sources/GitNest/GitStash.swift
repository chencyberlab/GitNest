import Foundation

/// One entry from `git stash list`, for the stash-management popover. Deliberately
/// minimal — the selector (`stash@{N}`) to act on and the description git shows for
/// it. Mirrors GitCommit/GitFileChange: the parser is kept separate from the shell
/// call so it can be unit-tested without a real repo.
struct GitStashEntry: Identifiable, Sendable {
    let id = UUID()
    let index: Int        // the N in stash@{N}; what apply/pop/drop act on
    let selector: String  // "stash@{N}" exactly as git reported it
    let hash: String      // full commit SHA; re-checked before a destructive op so a
                          // stack that shifted under us (external git, another row)
                          // can't make the action hit the wrong stash
    let subject: String   // git's description, e.g. "WIP on main: 1a2b3c4 Fix bug"
}

/// Pure parsing for `git stash list -z --format=…`, kept separate from the shell
/// call so it can be unit-tested without a real repo. Mirrors GitLog.
enum GitStash {
    /// Field separator we ask git to emit between the selector and the subject.
    static let fieldSeparator: Character = "\u{1f}"   // ASCII Unit Separator

    /// The `--format` string: the shortened reflog selector (`stash@{N}`), the full
    /// commit SHA (`%H`, for the re-validation guard), and the reflog subject (the
    /// human description), joined by the Unit Separator. The free-text subject is
    /// LAST and `parse` caps the split there: git permits arbitrary bytes — including
    /// this separator — in a stash message, so layout (not an assumption that the
    /// separator is absent) keeps the structured selector/SHA from being shifted.
    static let listFormat = "%gd%x1f%H%x1f%gs"

    /// Parse `git stash list -z` output (NUL-separated entries, each the
    /// Unit-Separator-joined selector + hash + subject) into entries. Tolerant of
    /// git's trailing NUL after the last entry.
    static func parse(listZ output: String) -> [GitStashEntry] {
        var entries: [GitStashEntry] = []
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            // maxSplits: 2 so a separator byte in the subject stays in the subject
            // rather than truncating it (the selector/SHA are earlier and immune
            // either way). Keep empty subsequences so a blank subject can't shift them.
            let fields = record
                .split(separator: fieldSeparator, maxSplits: 2, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 3 else { continue }   // malformed/truncated — skip
            let selector = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let hash = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = index(from: selector), !hash.isEmpty else { continue }
            // Free-text from the user's stash message — strip control/bidi bytes.
            entries.append(GitStashEntry(index: index, selector: selector, hash: hash,
                                         subject: fields[2].sanitizedForSingleLineDisplay()))
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

    /// The current commit SHA at `stash@{index}`, or nil if it no longer resolves
    /// (the stack shrank or shifted). Used to confirm an action still targets the
    /// stash the user saw before it mutates. Read-only and lock-free.
    static func stashHash(at path: String, index: Int) -> String? {
        let res = Shell.run([
            "git", "--no-optional-locks", "-C", path,
            "rev-parse", "--verify", "--quiet", "stash@{\(index)}",
        ])
        guard res.ok else { return nil }
        let hash = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// Save the working tree's changes (including untracked, so it matches what the
    /// row's change badge counts) onto the stash stack. A non-empty `message` labels
    /// the stash in `git stash list` (`-m`); blank keeps git's auto-generated "WIP on
    /// <branch>…" text. The message is passed as its own argv element (no shell), so
    /// spaces or quotes in it are safe. Exits 0 with "No local changes to save" when
    /// the tree is clean — callers should check for that.
    static func stashPush(at path: String, message: String = "") -> ShellResult {
        var args = ["git", "-C", path, "stash", "push", "--include-untracked"]
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { args += ["-m", trimmed] }
        return Shell.run(args)
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
