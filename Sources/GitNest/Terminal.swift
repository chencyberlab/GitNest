import Foundation

/// The GUI terminal a repo folder opens in. Persisted by raw value via @AppStorage.
enum PreferredTerminal: String, CaseIterable, Identifiable, Sendable {
    case none
    case terminal
    case iTerm2
    case ghostty
    case custom

    var id: String { rawValue }

    /// Label shown in the Settings picker.
    var menuTitle: String {
        switch self {
        case .none:     return "None / Disabled"
        case .terminal: return "macOS Terminal"
        case .iTerm2:   return "iTerm2"
        case .ghostty:  return "Ghostty"
        case .custom:   return "Custom..."
        }
    }

    /// The macOS application name passed to `open -a` for the built-in terminals.
    /// Empty for `.none`/`.custom`, which are resolved separately.
    var applicationName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm2:   return "iTerm"
        case .ghostty:  return "Ghostty"
        case .none, .custom:
            return ""
        }
    }

    /// Friendly name for buttons/logs, falling back to the custom field.
    func displayName(customAppName: String) -> String {
        switch self {
        case .none:
            return "Terminal"
        case .custom:
            let trimmed = customAppName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "your terminal" : trimmed
        default:
            return menuTitle
        }
    }
}

/// Why opening a repo in a terminal failed — each case maps to a friendly message.
enum TerminalOpenError: Error, Equatable, Sendable {
    case notConfigured
    case missingCustomAppName
    case launchFailed(String)
    case openFailed(appName: String, detail: String)
}

/// Opens a folder in a GUI terminal via `/usr/bin/open -a`. Uses `Process` with an
/// argument array (no shell string building), so paths with spaces are safe.
enum TerminalLauncher {
    /// Resolve the macOS app name for a choice, or throw for unusable choices.
    static func resolveAppName(_ terminal: PreferredTerminal, customAppName: String) throws -> String {
        switch terminal {
        case .none:
            throw TerminalOpenError.notConfigured
        case .custom:
            let trimmed = customAppName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw TerminalOpenError.missingCustomAppName }
            return trimmed
        default:
            return terminal.applicationName
        }
    }

    /// Open `path` in the chosen terminal. Blocking — run off the main actor.
    /// Returns the display name on success; throws `TerminalOpenError` otherwise.
    @discardableResult
    static func open(path: String, terminal: PreferredTerminal, customAppName: String) throws -> String {
        let appName = try resolveAppName(terminal, customAppName: customAppName)
        let displayName = terminal.displayName(customAppName: customAppName)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName, path]
        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw TerminalOpenError.launchFailed(error.localizedDescription)
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
            throw TerminalOpenError.openFailed(appName: displayName, detail: detail)
        }
        return displayName
    }

    /// A user-facing sentence for an open failure.
    static func message(for error: TerminalOpenError) -> String {
        switch error {
        case .notConfigured:
            return "No terminal selected. Choose one in Settings → Open in Terminal."
        case .missingCustomAppName:
            return "No custom terminal name set. Add it in Settings → Open in Terminal."
        case .launchFailed(let detail):
            return "Couldn't launch the terminal: \(detail)"
        case .openFailed(let appName, let detail):
            let base = "Couldn't open in “\(appName)”. Make sure the app is installed."
            return detail.isEmpty ? base : "\(base) (\(detail))"
        }
    }
}
