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
