import Darwin
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

        return runExecutable(
            executable: executable,
            arguments: Array(args.dropFirst()),
            cwd: cwd,
            environment: commandEnvironment(),
            timeout: timeout,
            displayArgs: args
        )
    }

    private static func commandEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let currentPath = environment["PATH"] ?? ""
        environment["PATH"] = developerPath + (currentPath.isEmpty ? "" : ":\(currentPath)")
        // There is no terminal to answer a username/password prompt on, so make
        // git fail fast instead of waiting forever on one.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }

    private static func runExecutable(executable: String,
                                      arguments: [String],
                                      cwd: String?,
                                      environment: [String: String],
                                      timeout: TimeInterval,
                                      displayArgs: [String]) -> ShellResult {
        var outFD: [Int32] = [0, 0]
        var errFD: [Int32] = [0, 0]
        guard pipe(&outFD) == 0 else {
            return ShellResult(exitCode: -1, stdout: "", stderr: "pipe failed: \(posixError(errno))")
        }
        guard pipe(&errFD) == 0 else {
            close(outFD[0]); close(outFD[1])
            return ShellResult(exitCode: -1, stdout: "", stderr: "pipe failed: \(posixError(errno))")
        }

        var actions: posix_spawn_file_actions_t? = nil
        var attrs: posix_spawnattr_t? = nil
        var setupError = posix_spawn_file_actions_init(&actions)
        guard setupError == 0 else {
            closePipe(outFD); closePipe(errFD)
            return ShellResult(exitCode: -1, stdout: "", stderr: "spawn setup failed: \(posixError(setupError))")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        setupError = posix_spawnattr_init(&attrs)
        guard setupError == 0 else {
            closePipe(outFD); closePipe(errFD)
            return ShellResult(exitCode: -1, stdout: "", stderr: "spawn setup failed: \(posixError(setupError))")
        }
        defer { posix_spawnattr_destroy(&attrs) }

        func record(_ code: Int32) {
            if setupError == 0, code != 0 { setupError = code }
        }

        record(posix_spawn_file_actions_adddup2(&actions, outFD[1], STDOUT_FILENO))
        record(posix_spawn_file_actions_adddup2(&actions, errFD[1], STDERR_FILENO))
        record(posix_spawn_file_actions_addclose(&actions, outFD[0]))
        record(posix_spawn_file_actions_addclose(&actions, errFD[0]))
        record(posix_spawn_file_actions_addclose(&actions, outFD[1]))
        record(posix_spawn_file_actions_addclose(&actions, errFD[1]))
        if let cwd {
            cwd.withCString { record(posix_spawn_file_actions_addchdir_np(&actions, $0)) }
        }

        // Put the launched command in its own process group. On timeout we kill
        // that group, not just the direct PID, so helper children that inherited
        // stdout/stderr cannot keep the read pipes open indefinitely.
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        record(posix_spawnattr_setflags(&attrs, flags))
        record(posix_spawnattr_setpgroup(&attrs, 0))

        guard setupError == 0 else {
            closePipe(outFD); closePipe(errFD)
            return ShellResult(exitCode: -1, stdout: "", stderr: "spawn setup failed: \(posixError(setupError))")
        }

        let argv = [executable] + arguments
        let env = environment.map { "\($0.key)=\($0.value)" }
        var pid = pid_t()
        let spawnResult = executable.withCString { executablePath in
            withCStringArray(argv) { argvPointer in
                withCStringArray(env) { envPointer in
                    posix_spawn(&pid, executablePath, &actions, &attrs, argvPointer, envPointer)
                }
            }
        }

        close(outFD[1])
        close(errFD[1])

        guard spawnResult == 0 else {
            close(outFD[0])
            close(errFD[0])
            return ShellResult(exitCode: -1, stdout: "", stderr: "failed to launch: \(posixError(spawnResult))")
        }

        let outHandle = FileHandle(fileDescriptor: outFD[0], closeOnDealloc: true)
        let errHandle = FileHandle(fileDescriptor: errFD[0], closeOnDealloc: true)

        // Read both pipes concurrently to avoid deadlock if one fills its buffer.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "shell.read", attributes: .concurrent)
        group.enter()
        queue.async { outData = outHandle.readDataToEndOfFile(); group.leave() }
        group.enter()
        queue.async { errData = errHandle.readDataToEndOfFile(); group.leave() }

        var waitStatus: Int32 = 0
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 {
                if errno != EINTR { break }
            }
            waitStatus = status
            exited.signal()
        }

        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        var processExited = false
        if exited.wait(timeout: deadline) == .timedOut {
            timedOut = true
            killProcessGroup(pid, SIGTERM, fallbackToProcess: true)
            if exited.wait(timeout: .now() + 5) == .timedOut {
                killProcessGroup(pid, SIGKILL, fallbackToProcess: true)
                exited.wait()
            }
            processExited = true
        } else {
            processExited = true
        }

        if group.wait(timeout: deadline) == .timedOut {
            timedOut = true
            killProcessGroup(pid, SIGTERM, fallbackToProcess: !processExited)
            if !processExited {
                if exited.wait(timeout: .now() + 5) == .timedOut {
                    killProcessGroup(pid, SIGKILL, fallbackToProcess: true)
                    exited.wait()
                }
                processExited = true
            }
            if group.wait(timeout: .now() + 5) == .timedOut {
                killProcessGroup(pid, SIGKILL, fallbackToProcess: false)
                group.wait()
            }
        } else {
            group.wait()
        }

        var stderrText = String(decoding: errData, as: UTF8.self)
        if timedOut {
            if !stderrText.isEmpty, !stderrText.hasSuffix("\n") { stderrText += "\n" }
            stderrText += "command timed out after \(Int(timeout))s: \(displayArgs.joined(separator: " "))"
        }
        return ShellResult(
            exitCode: timedOut ? -1 : exitCode(fromWaitStatus: waitStatus),
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: stderrText
        )
    }

    private static func closePipe(_ pipe: [Int32]) {
        close(pipe[0])
        close(pipe[1])
    }

    private static func killProcessGroup(_ pid: pid_t, _ signal: Int32, fallbackToProcess: Bool) {
        if kill(-pid, signal) != 0, fallbackToProcess {
            kill(pid, signal)
        }
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        if signal != 0x7f {
            return 128 + signal
        }
        return status
    }

    private static func posixError(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func withCStringArray<R>(_ strings: [String],
                                            _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        let cStrings = strings.map { strdup($0)! }
        defer { cStrings.forEach { free($0) } }
        var pointers = cStrings.map { Optional($0) }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
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
        let result = runExecutable(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v -- " + escaped],
            cwd: nil,
            environment: commandEnvironment(),
            timeout: executableLookupTimeout,
            displayArgs: ["/bin/zsh", "-lc", "command -v -- " + escaped]
        )
        guard result.ok else { return nil }

        let fm = FileManager.default
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }
    }
}
