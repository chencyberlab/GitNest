import Foundation

/// The GUI editor a repo folder opens in. Persisted by raw value via @AppStorage.
/// Focus is on macOS GUI apps opened with `open -a`, not CLI tools like `code`.
enum PreferredEditor: String, CaseIterable, Identifiable, Sendable {
    case none
    case visualStudioCode
    case cursor
    case windsurf
    case zed
    case xcode
    case custom

    var id: String { rawValue }

    /// Label shown in the Settings picker.
    var menuTitle: String {
        switch self {
        case .none:             return "None / Disabled"
        case .visualStudioCode: return "Visual Studio Code"
        case .cursor:           return "Cursor"
        case .windsurf:         return "Windsurf"
        case .zed:              return "Zed"
        case .xcode:            return "Xcode"
        case .custom:           return "Custom…"
        }
    }

    /// The macOS application name passed to `open -a` for the built-in editors.
    /// Empty for `.none`/`.custom`, which are resolved separately.
    var applicationName: String {
        switch self {
        case .visualStudioCode: return "Visual Studio Code"
        case .cursor:           return "Cursor"
        case .windsurf:         return "Windsurf"
        case .zed:              return "Zed"
        case .xcode:            return "Xcode"
        case .none, .custom:    return ""
        }
    }

    /// Friendly name for buttons/logs, falling back to the custom field.
    func displayName(customAppName: String) -> String {
        switch self {
        case .none:
            return "Editor"
        case .custom:
            let trimmed = customAppName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "your editor" : trimmed
        default:
            return applicationName
        }
    }
}

/// Why opening a repo in an editor failed — each case maps to a friendly message.
enum EditorOpenError: Error, Equatable, Sendable {
    case notConfigured
    case missingCustomAppName
    case launchFailed(String)
    case openFailed(appName: String, detail: String)
}

/// Opens a folder in a GUI editor via `/usr/bin/open -a`. Uses `Process` with an
/// argument array (no shell string building), so paths with spaces are safe.
enum EditorLauncher {
    /// Resolve the macOS app name for a choice, or throw for unusable choices.
    static func resolveAppName(_ editor: PreferredEditor, customAppName: String) throws -> String {
        switch editor {
        case .none:
            throw EditorOpenError.notConfigured
        case .custom:
            let trimmed = customAppName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw EditorOpenError.missingCustomAppName }
            return trimmed
        default:
            return editor.applicationName
        }
    }

    /// Open `path` in the chosen editor. Blocking — run off the main actor.
    /// Returns the resolved app name on success; throws `EditorOpenError` otherwise.
    @discardableResult
    static func open(path: String, editor: PreferredEditor, customAppName: String) throws -> String {
        let appName = try resolveAppName(editor, customAppName: customAppName)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName, path]
        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw EditorOpenError.launchFailed(error.localizedDescription)
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
            throw EditorOpenError.openFailed(appName: appName, detail: detail)
        }
        return appName
    }

    /// A user-facing sentence for an open failure.
    static func message(for error: EditorOpenError) -> String {
        switch error {
        case .notConfigured:
            return "No editor selected. Choose one in Settings → Open in Editor."
        case .missingCustomAppName:
            return "No custom editor name set. Add it in Settings → Open in Editor."
        case .launchFailed(let detail):
            return "Couldn't launch the editor: \(detail)"
        case .openFailed(let appName, let detail):
            let base = "Couldn't open in “\(appName)”. Make sure the app is installed."
            return detail.isEmpty ? base : "\(base) (\(detail))"
        }
    }
}
