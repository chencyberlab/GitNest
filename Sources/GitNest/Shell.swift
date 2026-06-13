import Foundation

/// Result of running an external command.
struct ShellResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { exitCode == 0 }
}

enum Shell {
    /// Standard locations searched first — Homebrew (Apple Silicon and Intel),
    /// then the system paths. Covers gh/git/ssh for the common installs even
    /// when the app is launched from Finder with a minimal PATH.
    private static let developerPathEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]
    private static let developerPath = developerPathEntries.joined(separator: ":")

    /// Hard ceiling on any single command. Purely a backstop so one hung
    /// ssh/git/gh can't wedge the serialized gh chain for the rest of the
    /// session — generous because clones and pushes of large repos are
    /// legitimately slow. Network-quick commands fail much earlier on their
    /// own (e.g. ssh's ConnectTimeout, GIT_TERMINAL_PROMPT=0).
    static let defaultTimeout: TimeInterval = 600
    private static let executableLookupTimeout: TimeInterval = 10

    /// Run a command directly (no intermediate shell). The first element is
    /// resolved against the developer PATH, so Homebrew's gh is found even
    /// when launched from a .app bundle via Finder. No shell also means no
    /// quoting pitfalls and no user dotfile output polluting stdout — `gh`'s
    /// JSON must arrive byte-exact.
    static func run(_ args: [String], cwd: String? = nil,
                    timeout: TimeInterval = defaultTimeout) -> ShellResult {
        guard let command = args.first else {
            return ShellResult(exitCode: -1, stdout: "", stderr: "no command given")
        }
        guard let executable = resolveExecutable(command) else {
            return ShellResult(exitCode: 127, stdout: "", stderr: "command not found: \(command)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(args.dropFirst())
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        var environment = ProcessInfo.processInfo.environment
        let currentPath = environment["PATH"] ?? ""
        environment["PATH"] = developerPath + (currentPath.isEmpty ? "" : ":\(currentPath)")
        // There is no terminal to answer a username/password prompt on, so make
        // git fail fast instead of waiting forever on one.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return ShellResult(exitCode: -1, stdout: "", stderr: "failed to launch: \(error)")
        }

        // Read both pipes concurrently to avoid deadlock if one fills its buffer.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "shell.read", attributes: .concurrent)
        group.enter()
        queue.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        queue.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            if process.isRunning { process.terminate() }   // SIGTERM first
            if exited.wait(timeout: .now() + 5) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                exited.wait()
            }
        }
        group.wait()

        var stderrText = String(decoding: errData, as: UTF8.self)
        if timedOut {
            if !stderrText.isEmpty, !stderrText.hasSuffix("\n") { stderrText += "\n" }
            stderrText += "command timed out after \(Int(timeout))s: \(args.joined(separator: " "))"
        }
        return ShellResult(
            exitCode: timedOut ? -1 : process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: stderrText
        )
    }

    // MARK: Binary lookup

    private static let cacheLock = NSLock()
    private static var executableCache: [String: String] = [:]

    /// Absolute path for `command`: the developer PATH and inherited PATH are
    /// checked directly, then — for unusual setups (MacPorts, nix) — a login
    /// shell is asked once via `command -v`. Successful lookups are cached;
    /// misses are not, so installing a missing tool works without a relaunch.
    static func resolveExecutable(_ command: String) -> String? {
        if command.contains("/") { return command }   // explicit path — use as-is

        cacheLock.lock()
        let cached = executableCache[command]
        cacheLock.unlock()
        if let cached { return cached }

        guard let found = findExecutable(command) else { return nil }
        cacheLock.lock()
        executableCache[command] = found
        cacheLock.unlock()
        return found
    }

    private static func findExecutable(_ command: String) -> String? {
        let fm = FileManager.default
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for dir in developerPathEntries + inherited {
            let candidate = (dir as NSString).appendingPathComponent(command)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return loginShellLookup(command)
    }

    /// Last-resort lookup through the user's login shell, for tools installed
    /// outside the standard prefixes. Profile output can pollute stdout, so
    /// only a line that is an actual executable path is trusted.
    private static func loginShellLookup(_ command: String) -> String? {
        let escaped = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v -- " + escaped]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        guard (try? process.run()) != nil else { return nil }

        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if exited.wait(timeout: .now() + executableLookupTimeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                exited.wait()
            }
        }
        group.wait()
        guard process.terminationStatus == 0 else { return nil }

        let fm = FileManager.default
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }
    }
}
