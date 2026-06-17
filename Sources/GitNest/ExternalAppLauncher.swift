import Foundation

/// Shared machinery for opening a repo folder in a GUI app (editor or terminal)
/// via `/usr/bin/open -a`. Both `EditorLauncher` and `TerminalLauncher` delegate
/// here so the blocking `Process` dance — argument array (no shell), stderr-drain
/// ordering, and exit-code classification — lives in exactly one place. The two
/// launchers keep their own error types and user-facing copy ("editor" vs
/// "terminal"), since those are what callers and tests pin; only the launch
/// mechanics and the custom-name trim are shared here.
enum ExternalAppLauncher {
    /// Why an open attempt failed — kept domain-neutral so either launcher can map
    /// it onto its own typed error in one place.
    enum Failure: Sendable, Equatable {
        case launchFailed(String)
        case openFailed(appName: String, detail: String)
    }

    /// Result of launching `open -a`. Carries the display name on success (the
    /// name callers show in logs/buttons; for iTerm2 this is "iTerm", not the raw
    /// "iTerm" app name — kept identical because `open -a` wants the app name and
    /// the user sees the same string).
    enum Outcome: Sendable, Equatable {
        case opened(displayName: String)
        case failed(Failure)
    }

    /// Trim a custom app name, returning nil when it's blank. Shared so both
    /// launchers apply the identical "trim then reject empty" rule for the
    /// `.custom` choice.
    static func resolveCustomAppName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Open `path` in the app named `appName` (passed to `open -a`) via
    /// `/usr/bin/open -a`, surfacing it to the user as `displayName`. Blocking —
    /// run off the main actor. Uses `Process` with an argument array (no shell
    /// string building), so paths with spaces are safe.
    static func launch(path: String, appName: String, displayName: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName, path]
        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return .failed(.launchFailed(error.localizedDescription))
        }
        // Drain stderr before waiting: readDataToEndOfFile() returns at the child's
        // EOF, so reading first can't deadlock on a full pipe buffer the way reading
        // after waitUntilExit() can (harmless for `open`, but the safe ordering).
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // `open` exits non-zero (and explains on stderr) when the app isn't found.
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(.openFailed(appName: displayName, detail: detail))
        }
        return .opened(displayName: displayName)
    }
}
