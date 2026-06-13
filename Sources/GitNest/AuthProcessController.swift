import Foundation

/// Owns the in-flight `gh auth login --web` process so that cancelling the
/// Add-account wizard (or starting another sign-in) can kill its GitHub poll
/// instead of leaving it to block the serialized gh chain for minutes.
@MainActor
final class AuthProcessController {
    private var activeAuthProcess: Shell.ProcessHandle?

    func start() -> Shell.ProcessHandle {
        activeAuthProcess?.cancel()
        let process = Shell.ProcessHandle()
        activeAuthProcess = process
        return process
    }

    func finish(_ process: Shell.ProcessHandle) {
        if activeAuthProcess === process { activeAuthProcess = nil }
    }

    func cancel() {
        activeAuthProcess?.cancel()
        activeAuthProcess = nil
    }
}
