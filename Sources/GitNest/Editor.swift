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
/// Delegates the actual `Process` launch to `ExternalAppLauncher` so the editor
/// and terminal launchers share one copy of the blocking-mechanics code.
enum EditorLauncher {
    /// Resolve the macOS app name for a choice, or throw for unusable choices.
    static func resolveAppName(_ editor: PreferredEditor, customAppName: String) throws -> String {
        switch editor {
        case .none:
            throw EditorOpenError.notConfigured
        case .custom:
            guard let trimmed = ExternalAppLauncher.resolveCustomAppName(customAppName) else {
                throw EditorOpenError.missingCustomAppName
            }
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
        switch ExternalAppLauncher.launch(path: path, appName: appName, displayName: appName) {
        case .opened(let displayName):
            return displayName
        case .failed(.launchFailed(let detail)):
            throw EditorOpenError.launchFailed(detail)
        case .failed(.openFailed(let appName, let detail)):
            throw EditorOpenError.openFailed(appName: appName, detail: detail)
        }
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
