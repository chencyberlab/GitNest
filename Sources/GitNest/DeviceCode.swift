import Foundation

/// Parsing for the one-time device code used by `gh auth login --web`
/// (e.g. "! First copy your one-time code: 57C6-CEA6").
///
/// Two deliberately different strictness levels:
///  • gh's own output is trusted, so a code is accepted anywhere in the text —
///    but anchored so fragments of longer hyphenated runs (UUIDs, serial
///    numbers) can't masquerade as a code.
///  • The clipboard is unrelated user data most of the time. `--clipboard`
///    sets it to *exactly* the code, so only a whole-string match is accepted;
///    a copied UUID containing "e29b-41d4" must not be shown as the code.
enum DeviceCode {
    /// XXXX-XXXX, not butting up against more alphanumerics or hyphens.
    private static let anchoredPattern =
        #"(?<![A-Za-z0-9-])[A-Z0-9]{4}-[A-Z0-9]{4}(?![A-Za-z0-9-])"#

    /// Extract the code from `gh auth login` output, or nil when absent.
    static func extract(fromGhOutput text: String) -> String? {
        guard let range = text.range(of: anchoredPattern,
                                     options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return text[range].uppercased()
    }

    /// Read the code from clipboard contents, which must be the code alone
    /// (modulo surrounding whitespace). Returns nil for anything else.
    static func extract(fromClipboard text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[A-Z0-9]{4}-[A-Z0-9]{4}$"#,
                            options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return trimmed.uppercased()
    }
}
