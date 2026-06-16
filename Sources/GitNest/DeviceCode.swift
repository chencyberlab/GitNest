import Foundation
import AppKit

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

/// Polls the clipboard for a GitHub device code while an auth flow runs.
/// Only reads the pasteboard when its `changeCount` advances, so it does not
/// repeatedly trigger macOS clipboard-privacy alerts.
///
/// `@MainActor` so the `NSPasteboard` reads stay on the main thread (the loop's
/// `await Task.sleep` releases the actor while suspended, so polling doesn't
/// block it). This matches the callers, which are themselves main-actor isolated.
@MainActor
enum DeviceCodeWatcher {
    /// Watch the clipboard for up to `maxIterations` * `intervalNanoseconds`.
    /// Returns the first code that appears alone on the clipboard, or `nil` if
    /// the loop expires or the task is cancelled.
    ///
    /// `currentChangeCount` / `readClipboard` default to the system pasteboard
    /// but are injectable, so tests can drive an in-memory clipboard instead of
    /// reading (and clobbering) the real, shared one. Same closure-seam style as
    /// the shell-backed dependencies in `ProjectWorkflow` — no protocol needed.
    static func watchClipboard(startingChangeCount: Int,
                               maxIterations: Int,
                               intervalNanoseconds: UInt64 = 500_000_000,
                               currentChangeCount: () -> Int = { NSPasteboard.general.changeCount },
                               readClipboard: () -> String? = { NSPasteboard.general.string(forType: .string) }) async -> String? {
        var lastChangeCount = startingChangeCount
        let iterations = max(0, maxIterations)
        for _ in 0..<iterations {
            if Task.isCancelled { return nil }
            let current = currentChangeCount()
            if current != lastChangeCount {
                lastChangeCount = current
                if let clip = readClipboard(),
                   let code = DeviceCode.extract(fromClipboard: clip) {
                    return code
                }
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return nil
    }
}
