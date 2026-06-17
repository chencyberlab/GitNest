import SwiftUI
import Combine

@MainActor
final class LogStore: ObservableObject {
    /// Cap the Output log so an always-open session stays flat in memory.
    static let maxLogLines = 500

    @Published var log: String = ""

    /// Whether the most recently appended log line was a failure/warning. The
    /// collapsed Output status line uses this to stay pinned on problems while
    /// progress/success lines fade away on their own.
    @Published var lastWasError = false

    func append(_ message: String) {
        // Scrub at the sink so every line — progress text, raw gh/git output, error
        // detail — is credential-free and home-dir-folded regardless of its source.
        let message = Redaction.scrub(message)
        log += message + "\n"
        // Marker is always at the start of the message, even when the body spans
        // several lines, so this stays correct for multi-line error output.
        lastWasError = message.hasPrefix("✗") || message.hasPrefix("⚠")
        enforceLogLimit()
    }

    /// Keep only the most recent `maxLogLines` lines. Counts real lines, so it
    /// handles multi-line entries (e.g. command output) correctly.
    private func enforceLogLimit() {
        var lines = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }   // drop the empty tail from the final "\n"
        guard lines.count > Self.maxLogLines else { return }
        log = lines.suffix(Self.maxLogLines).joined(separator: "\n") + "\n"
    }

    func report(_ res: ShellResult, ok: String) {
        let out = (res.stdout + res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if res.ok {
            append("✓ \(ok)" + (out.isEmpty ? "" : "\n\(out)"))
        } else {
            append("✗ \(out.isEmpty ? "failed" : out)")
        }
    }
}
