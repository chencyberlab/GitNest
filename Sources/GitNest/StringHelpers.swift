import Foundation

extension Optional where Wrapped == String {
    /// Returns the wrapped string when it is non-nil and not empty; otherwise `nil`.
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

/// Sanitise a folder name so it is a valid GitHub repository name.
///
/// GitHub repo names are ASCII `[A-Za-z0-9._-]`. `CharacterSet.alphanumerics` is
/// Unicode-aware, so it would pass "héllo" through unchanged — which `gh`
/// rejects (or GitHub silently renames, desyncing `repoFullName`).
func sanitizedRepoName(from folderName: String) -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    var name = String(folderName.map { allowed.contains($0) ? $0 : "-" })
    while name.contains("--") {
        name = name.replacingOccurrences(of: "--", with: "-")
    }
    name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
    if name.count > 100 { name = String(name.prefix(100)) }
    name = name.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
    return name.isEmpty ? "new-repo" : name
}

/// Whether `name` is a valid GitHub user/organization login — the rule every
/// account alias (`login.lowercased()`) and SSH host suffix (`github-<alias>`)
/// must satisfy, since the alias flows into file paths (`id_<alias>`,
/// `~/.gitconfig-<alias>`) and `gh auth switch -u <alias>`.
///
/// GitHub's own login rules: alphanumerics and single hyphens, 1–39 chars, no
/// leading/trailing/double hyphens. Reused for owner/repo parsing and for
/// validating aliases read back from disk, so the two trust boundaries agree.
func isValidGitHubLogin(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 39 else { return false }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
    guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
    guard !name.hasPrefix("-"), !name.hasSuffix("-") else { return false }
    guard !name.contains("--") else { return false }
    return true
}
