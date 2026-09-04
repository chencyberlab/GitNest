import Foundation

extension Optional where Wrapped == String {
    /// Returns the wrapped string when it is non-nil and not empty; otherwise `nil`.
    var nilIfEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

extension String {
    /// Strip bytes that can corrupt or visually spoof a one-line display: C0/C1
    /// control characters (including NUL, ESC, and the `\u{1f}` field separator git
    /// emits in `--pretty`/`--format` output) and Unicode format characters — among
    /// them the bidirectional embeddings, overrides, and isolates behind "Trojan
    /// Source" (CVE-2021-42574). Zero-width joiners are deliberately kept so a
    /// legitimate emoji sequence ("👨‍👩‍👧") or script ligature still renders as one
    /// grapheme. Applied to untrusted single-line git text (commit subject, author
    /// name, stash message) before it reaches the UI.
    func sanitizedForSingleLineDisplay() -> String {
        var out = String.UnicodeScalarView()
        for scalar in unicodeScalars where !Self.unsafeDisplayScalars.contains(scalar) {
            out.append(scalar)
        }
        return String(out)
    }

    /// Unicode Cc + Cf (control + format): C0/C1 controls, the `\u{1f}` separator,
    /// bidi overrides/isolates, BOM, … minus the zero-width joiners emoji and some
    /// scripts depend on — removing those would split a grapheme cluster.
    private static let unsafeDisplayScalars: CharacterSet = {
        var set = CharacterSet.controlCharacters
        set.subtract(CharacterSet(charactersIn: "\u{200C}\u{200D}"))   // ZWNJ, ZWJ
        return set
    }()

    /// Same threat model as `sanitizedForSingleLineDisplay()` — in particular the
    /// bidi overrides/isolates behind "Trojan Source" (CVE-2021-42574) — but for a
    /// verbatim line of source code (a diff line, a hunk header) rather than a git
    /// metadata label. A hard tab is common, legitimate indentation there, so unlike
    /// the label sanitizer it is preserved instead of stripped.
    ///
    /// The result is also capped: a diff of a minified bundle has single lines
    /// hundreds of kilobytes long, and handing one of those to a `Text` that sizes
    /// to its ideal width wedges layout. Truncation is marked with an ellipsis, and
    /// only affects display — search still matches against the full line.
    func sanitizedForCodeLineDisplay(maxCharacters: Int = 1000) -> String {
        var out = String()
        var kept = 0
        // Grapheme-by-grapheme rather than scalar-by-scalar: the cap must not be
        // able to cut an emoji sequence in half. Lazily walked, so a 500 KB line
        // is never fully traversed.
        for character in self {
            guard kept < maxCharacters else {
                out.append("…")
                break
            }
            var scalars = String.UnicodeScalarView()
            for scalar in character.unicodeScalars
            where scalar == "\t" || !Self.unsafeDisplayScalars.contains(scalar) {
                scalars.append(scalar)
            }
            guard !scalars.isEmpty else { continue }
            out.unicodeScalars.append(contentsOf: scalars)
            kept += 1
        }
        return out
    }

    /// Sanitize untrusted prose while preserving ordinary line breaks and tabs.
    /// Commit bodies need their paragraph structure, but can carry the same bidi
    /// and control bytes as subjects. The total cap prevents a crafted multi-megabyte
    /// message from making SwiftUI measure an unbounded `Text` view.
    func sanitizedForMultilineDisplay(maxCharacters: Int = 20_000) -> String {
        var out = String()
        var kept = 0
        for character in self {
            guard kept < maxCharacters else {
                out.append("…")
                break
            }
            var scalars = String.UnicodeScalarView()
            for scalar in character.unicodeScalars
            where scalar == "\n" || scalar == "\t" || !Self.unsafeDisplayScalars.contains(scalar) {
                scalars.append(scalar)
            }
            guard !scalars.isEmpty else { continue }
            out.unicodeScalars.append(contentsOf: scalars)
            kept += 1
        }
        return out
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
