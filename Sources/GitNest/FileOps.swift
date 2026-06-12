import Foundation

enum FileOps {
    /// Move a folder to the macOS Trash (recoverable). Reported via ShellResult
    /// so it logs the same way as git/gh actions.
    static func moveToTrash(_ path: String) -> ShellResult {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return ShellResult(exitCode: 1, stdout: "", stderr: "not found: \(path)")
        }
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return ShellResult(exitCode: 0, stdout: "moved to \(resultingURL?.path ?? "Trash")", stderr: "")
        } catch {
            return ShellResult(exitCode: 1, stdout: "", stderr: error.localizedDescription)
        }
    }
}
