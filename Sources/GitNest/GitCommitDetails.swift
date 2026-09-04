import Foundation

/// Stable routing data for one commit-details window. Capturing the local path
/// keeps an already-open window tied to the intended account if selection changes.
struct CommitDetailTarget: Codable, Hashable, Sendable {
    let repoName: String
    let nameWithOwner: String
    let accountAlias: String
    let localPath: String
    let hash: String
    let shortHash: String

    var id: String { "\(accountAlias)|\(nameWithOwner)|\(localPath)|\(hash)" }
}

/// Metadata Git stores on one commit. `message` includes the subject and body.
struct GitCommitDetail: Sendable {
    let hash: String
    let shortHash: String
    let authoredAt: String
    let parentHashes: [String]
    let author: String
    let message: String

    var subject: String {
        message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }
}

/// An immutable commit plus the files changed relative to its first parent. A root
/// commit has no parent and is compared with an empty tree.
struct GitCommitSnapshot: Sendable {
    let detail: GitCommitDetail
    let files: [GitFileChange]

    var comparisonDescription: String {
        guard let parent = detail.parentHashes.first else { return "Root commit · compared with an empty tree" }
        if detail.parentHashes.count > 1 {
            return "Merge commit · compared with first parent \(parent.prefix(12))"
        }
        return "Compared with parent \(parent.prefix(12))"
    }
}

/// Pure parsing for commit metadata and `git diff --name-status -z` output.
enum GitCommitDetails {
    /// NUL is used between fields because the message is multiline and can contain
    /// every printable separator. Structured fields come first; untrusted author
    /// and message fields stay last and are sanitized before display.
    static let metadataFormat = "%H%x00%h%x00%aI%x00%P%x00%an%x00%B"

    static func isValidObjectID(_ value: String) -> Bool {
        guard value.count == 40 || value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
        }
    }

    static func parse(metadataZ output: String) -> GitCommitDetail? {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6 else { return nil }
        let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let shortHash = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidObjectID(hash), !shortHash.isEmpty else { return nil }

        let parents = fields[3]
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard parents.allSatisfy(isValidObjectID) else { return nil }

        return GitCommitDetail(
            hash: hash,
            shortHash: shortHash,
            authoredAt: fields[2].trimmingCharacters(in: .whitespacesAndNewlines),
            parentHashes: parents,
            author: fields[4].sanitizedForSingleLineDisplay(),
            message: fields[5]
                .trimmingCharacters(in: .newlines)
                .sanitizedForMultilineDisplay()
        )
    }

    /// Parse alternating status/path tokens. Rename and copy statuses consume old
    /// and new paths; malformed trailing records are skipped without borrowing the
    /// next status token as a filename.
    static func parse(nameStatusZ output: String) -> [GitFileChange] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var files: [GitFileChange] = []
        var index = 0
        while index < tokens.count {
            let rawStatus = tokens[index]
            index += 1
            guard let code = rawStatus.first else { continue }
            if code == "R" || code == "C" {
                guard index + 1 < tokens.count,
                    !tokens[index].isEmpty,
                    !tokens[index + 1].isEmpty
                else { break }
                let originalPath = tokens[index]
                let path = tokens[index + 1]
                index += 2
                files.append(GitFileChange(path: path, originalPath: originalPath, status: .renamed))
                continue
            }
            guard index < tokens.count, !tokens[index].isEmpty else { break }
            let path = tokens[index]
            index += 1
            files.append(GitFileChange(path: path, originalPath: nil, status: status(for: code, raw: rawStatus)))
        }
        return files
    }

    private static func status(for code: Character, raw: String) -> GitChangeStatus {
        switch code {
        case "M", "T": return .modified
        case "A": return .added
        case "D": return .deleted
        case "U": return .conflicted
        default: return .other(raw)
        }
    }
}

extension GitHub {
    /// Load metadata and the changed-file inventory for one local commit. Merge
    /// commits are compared with their first parent, matching a conventional commit
    /// page. Both reads are local, lock-free, and leave the repository untouched.
    static func commitSnapshot(at path: String, hash: String) -> Result<GitCommitSnapshot, CommandError> {
        guard GitCommitDetails.isValidObjectID(hash) else {
            return .failure(CommandError(message: "The selected commit identifier is invalid."))
        }
        let metadata = Shell.run([
            "git", "--no-optional-locks", "-C", path,
            "show", "-s", "-z", "--no-color", "--format=\(GitCommitDetails.metadataFormat)", hash,
        ])
        guard metadata.ok,
            let detail = GitCommitDetails.parse(metadataZ: metadata.stdout),
            detail.hash.caseInsensitiveCompare(hash) == .orderedSame
        else {
            return .failure(CommandError(message: commitError(metadata, fallback: "could not read commit metadata")))
        }

        let fileResult: ShellResult
        if let parent = detail.parentHashes.first {
            fileResult = Shell.run([
                "git", "--no-optional-locks", "-C", path,
                "diff", "--no-ext-diff", "--no-color", "--no-textconv",
                "--name-status", "-z", "--find-renames", parent, hash, "--",
            ])
        } else {
            fileResult = Shell.run([
                "git", "--no-optional-locks", "-C", path,
                "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z",
                "--find-renames", hash,
            ])
        }
        guard fileResult.ok else {
            return .failure(CommandError(message: commitError(fileResult, fallback: "could not read changed files")))
        }
        return .success(
            GitCommitSnapshot(
                detail: detail,
                files: GitCommitDetails.parse(nameStatusZ: fileResult.stdout)))
    }

    /// Load one selected file's patch for an immutable commit snapshot. Blob-size
    /// checks happen first so generated assets cannot make Git or SwiftUI allocate an
    /// enormous patch merely because the user selected the file.
    static func commitFileDiff(
        at path: String,
        snapshot: GitCommitSnapshot,
        file: GitFileChange
    ) -> Result<GitFileDiff, CommandError> {
        let hash = snapshot.detail.hash
        guard GitCommitDetails.isValidObjectID(hash),
            snapshot.detail.parentHashes.allSatisfy(GitCommitDetails.isValidObjectID)
        else {
            return .failure(CommandError(message: "The selected commit identifier is invalid."))
        }

        let maxSourceBytes = 8 * 1024 * 1024
        if committedBlobTooLarge(
            at: path,
            snapshot: snapshot,
            file: file,
            limit: maxSourceBytes)
        {
            return .success(
                GitFileDiff(
                    additions: 0,
                    deletions: 0,
                    content: .tooLarge(limitBytes: maxSourceBytes)))
        }

        var arguments: [String]
        if let parent = snapshot.detail.parentHashes.first {
            arguments = [
                "git", "--no-optional-locks", "-C", path,
                "diff", "--no-ext-diff", "--no-color", "--no-textconv",
                "--find-renames", "--unified=3", parent, hash, "--",
            ]
        } else {
            arguments = [
                "git", "--no-optional-locks", "-C", path,
                "show", "--no-ext-diff", "--no-color", "--no-textconv",
                "--format=", "--root", "--find-renames", "--unified=3", hash, "--",
            ]
        }
        if let originalPath = file.originalPath {
            arguments.append(originalPath)
        }
        arguments.append(file.path)

        let result = Shell.run(arguments)
        guard result.ok else {
            return .failure(CommandError(message: commitError(result, fallback: "could not read commit diff")))
        }
        return .success(GitDiffParser.parse(unifiedPatch: result.stdout))
    }

    private static func committedBlobTooLarge(
        at repoPath: String,
        snapshot: GitCommitSnapshot,
        file: GitFileChange,
        limit: Int
    ) -> Bool {
        var revisionsAndPaths = [(snapshot.detail.hash, file.path)]
        if let parent = snapshot.detail.parentHashes.first {
            revisionsAndPaths.append((parent, file.originalPath ?? file.path))
        }
        for (revision, filePath) in revisionsAndPaths {
            let size = Shell.run([
                "git", "--no-optional-locks", "-C", repoPath,
                "cat-file", "-s", "\(revision):\(filePath)",
            ])
            guard size.ok,
                let bytes = Int64(size.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            if bytes > Int64(limit) { return true }
        }
        return false
    }

    private static func commitError(_ result: ShellResult, fallback: String) -> String {
        let raw = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? fallback : raw
    }
}
