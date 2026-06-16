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
    /// Pipe output collected under a lock, appended chunk by chunk as it
    /// arrives. The lock makes it safe to snapshot from the waiting thread
    /// even when a reader has to be abandoned (a stray child outside the
    /// process group can hold the write end open indefinitely), and the
    /// incremental appends mean a timed-out command still reports whatever
    /// it managed to print.
    private final class PipeBuffers: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()

        func appendOut(_ chunk: Data) { lock.lock(); out.append(chunk); lock.unlock() }
        func appendErr(_ chunk: Data) { lock.lock(); err.append(chunk); lock.unlock() }
        func snapshot() -> (out: Data, err: Data) {
            lock.lock(); defer { lock.unlock() }
            return (out, err)
        }
    }

    /// The reaped child's wait status, handed from the waitpid task to the runner.
    /// The `exited` semaphore already orders the write-before-read, but routing it
    /// through a locked box (rather than mutable vars captured by the dispatch
    /// block) keeps the hand-off explicit so it stays clean under TSan and Swift 6
    /// strict concurrency.
    private final class WaitOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32 = 0
        private var failed = false

        func record(status: Int32, failed: Bool) {
            lock.lock(); self.status = status; self.failed = failed; lock.unlock()
        }
        func read() -> (status: Int32, failed: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (status, failed)
        }
    }

    /// A handle to a running command's process group so another task can kill it
    /// mid-flight — e.g. the user cancelling the Add-account wizard while
    /// `gh auth login --web` is still polling GitHub. Thread-safe: the runner
    /// registers the pid once the child is spawned and clears it once reaped, so a
    /// late `cancel()` can never signal a recycled pid; `cancel()` itself is safe to
    /// call before, during, or after the command runs.
    final class ProcessHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        private var cancelled = false

        /// Returns false if `cancel()` already fired — the runner should then kill
        /// the just-spawned child immediately rather than let it run.
        fileprivate func register(_ pid: pid_t) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            self.pid = pid
            return true
        }

        fileprivate func clear() {
            lock.lock(); pid = nil; lock.unlock()
        }

        /// Kill the command's process group now, or as soon as it spawns.
        func cancel() {
            lock.lock()
            cancelled = true
            let target = pid
            lock.unlock()
            guard let target else { return }
            if kill(-target, SIGKILL) != 0 { kill(target, SIGKILL) }
        }
    }

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
    /// How long each kill-escalation step (SIGTERM → SIGKILL → abandon) waits.
    /// Overridable per call so tests don't sit through real grace periods.
    static let defaultKillGracePeriod: TimeInterval = 5
    private static let executableLookupTimeout: TimeInterval = 10

    /// Run a command directly (no intermediate shell). The first element is
    /// resolved against the developer PATH, so Homebrew's gh is found even
    /// when launched from a .app bundle via Finder. No shell also means no
    /// quoting pitfalls and no user dotfile output polluting stdout — `gh`'s
    /// JSON must arrive byte-exact.
    static func run(_ args: [String], cwd: String? = nil,
                    timeout: TimeInterval = defaultTimeout,
                    killGracePeriod: TimeInterval = defaultKillGracePeriod,
                    handle: ProcessHandle? = nil) -> ShellResult {
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
            killGracePeriod: killGracePeriod,
            displayArgs: args,
            handle: handle
        )
    }

    static func sanitizedEnvironment(from base: [String: String]) -> [String: String] {
        var environment = base
        for key in Array(environment.keys) where key.hasPrefix("GIT_") {
            environment.removeValue(forKey: key)
        }

        let currentPath = environment["PATH"] ?? ""
        environment["PATH"] = developerPath + (currentPath.isEmpty ? "" : ":\(currentPath)")
        // There is no terminal to answer a username/password prompt on, so make
        // git fail fast instead of waiting forever on one.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        return environment
    }

    private static func commandEnvironment() -> [String: String] {
        sanitizedEnvironment(from: ProcessInfo.processInfo.environment)
    }

    private static func runExecutable(executable: String,
                                      arguments: [String],
                                      cwd: String?,
                                      environment: [String: String],
                                      timeout: TimeInterval,
                                      killGracePeriod: TimeInterval,
                                      displayArgs: [String],
                                      handle: ProcessHandle? = nil) -> ShellResult {
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

        // stdin: /dev/null, explicitly. Tools that try to read input get EOF
        // immediately instead of waiting forever, and CLOEXEC_DEFAULT below
        // would otherwise leave the child with fd 0 closed entirely (the next
        // file it opened would silently become its stdin).
        record(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        record(posix_spawn_file_actions_adddup2(&actions, outFD[1], STDOUT_FILENO))
        record(posix_spawn_file_actions_adddup2(&actions, errFD[1], STDERR_FILENO))
        record(posix_spawn_file_actions_addclose(&actions, outFD[0]))
        record(posix_spawn_file_actions_addclose(&actions, errFD[0]))
        record(posix_spawn_file_actions_addclose(&actions, outFD[1]))
        record(posix_spawn_file_actions_addclose(&actions, errFD[1]))
        if let cwd {
            cwd.withCString { record(posix_spawn_file_actions_addchdir_np(&actions, $0)) }
        }

        // SETPGROUP: put the launched command in its own process group. On
        // timeout we kill that group, not just the direct PID, so helper
        // children that inherited stdout/stderr cannot keep the read pipes
        // open indefinitely.
        // CLOEXEC_DEFAULT (Apple extension): every descriptor except the ones
        // set up by the file actions above is closed in the child, so the
        // app's sockets and files never leak into git/gh/ssh.
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        record(posix_spawnattr_setflags(&attrs, flags))
        record(posix_spawnattr_setpgroup(&attrs, 0))

        guard setupError == 0 else {
            closePipe(outFD); closePipe(errFD)
            return ShellResult(exitCode: -1, stdout: "", stderr: "spawn setup failed: \(posixError(setupError))")
        }

        let argv = [executable] + arguments
        let env = environment.map { "\($0.key)=\($0.value)" }
        var pid = pid_t()
        guard let spawnResult = executable.withCString({ executablePath in
            withCStringArray(argv) { argvPointer in
                withCStringArray(env) { envPointer in
                    posix_spawn(&pid, executablePath, &actions, &attrs, argvPointer, envPointer)
                }
            }
        }) else {
            closePipe(outFD); closePipe(errFD)
            return ShellResult(exitCode: -1, stdout: "", stderr: "out of memory preparing command arguments")
        }

        close(outFD[1])
        close(errFD[1])

        guard spawnResult == 0 else {
            close(outFD[0])
            close(errFD[0])
            return ShellResult(exitCode: -1, stdout: "", stderr: "failed to launch: \(posixError(spawnResult))")
        }

        // Expose the process group for external cancellation. If `cancel()` already
        // fired (the wizard was dismissed between spawn and here), kill it now.
        if let handle, !handle.register(pid) {
            killProcessGroup(pid, SIGKILL, fallbackToProcess: true)
        }

        let outHandle = FileHandle(fileDescriptor: outFD[0], closeOnDealloc: true)
        let errHandle = FileHandle(fileDescriptor: errFD[0], closeOnDealloc: true)

        // Read both pipes concurrently to avoid deadlock if one fills its
        // buffer. Chunks land in the lock-guarded buffers as they arrive, so a
        // snapshot is safe (and meaningful) even if a reader never finishes.
        let buffers = PipeBuffers()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "shell.read", attributes: .concurrent)
        group.enter()
        queue.async { drain(outHandle) { buffers.appendOut($0) }; group.leave() }
        group.enter()
        queue.async { drain(errHandle) { buffers.appendErr($0) }; group.leave() }

        let waitOutcome = WaitOutcome()
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(pid, &status, 0)
            } while result == -1 && errno == EINTR
            // A non-EINTR failure leaves `status` at 0, which decodes to exit 0 —
            // i.e. a failed wait would silently report success. Flag it instead.
            waitOutcome.record(status: status, failed: result == -1)
            exited.signal()
        }

        let deadline = DispatchTime.now() + timeout
        var timedOut = false

        // Phase 1: the direct child. This always terminates — SIGKILL on the
        // child itself cannot be ignored, so the final wait is bounded in
        // practice. After this point the child is reaped and `waitStatus` is
        // safe to read (ordered by the semaphore).
        if exited.wait(timeout: deadline) == .timedOut {
            timedOut = true
            killProcessGroup(pid, SIGTERM, fallbackToProcess: true)
            if exited.wait(timeout: .now() + killGracePeriod) == .timedOut {
                killProcessGroup(pid, SIGKILL, fallbackToProcess: true)
                exited.wait()
            }
        }
        // The child is reaped now; stop the handle from signalling a recycled pid.
        handle?.clear()

        // Phase 2: pipe EOF. Children that inherited stdout/stderr keep the
        // write ends open past the child's own exit; the group kills sweep
        // them. A child that escaped the process group entirely (setsid — an
        // ssh ControlPersist master, a daemonized helper) survives even
        // SIGKILL of the group, so as the last resort the readers are
        // abandoned rather than left to wedge this thread forever. The
        // abandoned reader exits, and its fd closes, whenever the stray
        // process finally does.
        var readersAbandoned = false
        if group.wait(timeout: deadline) == .timedOut {
            timedOut = true
            killProcessGroup(pid, SIGTERM, fallbackToProcess: false)
            if group.wait(timeout: .now() + killGracePeriod) == .timedOut {
                killProcessGroup(pid, SIGKILL, fallbackToProcess: false)
                if group.wait(timeout: .now() + killGracePeriod) == .timedOut {
                    readersAbandoned = true
                }
            }
        }

        let (outData, errData) = buffers.snapshot()
        // Safe to read now: the child is reaped and `exited` was signalled, which
        // happens-before this point on every path out of phase 1 above.
        let (waitStatus, waitFailed) = waitOutcome.read()
        var stderrText = String(decoding: errData, as: UTF8.self)
        if timedOut {
            if !stderrText.isEmpty, !stderrText.hasSuffix("\n") { stderrText += "\n" }
            stderrText += "command timed out after \(Int(timeout))s: \(displayArgs.joined(separator: " "))"
            if readersAbandoned {
                stderrText += "\n(a stray child process still holds the command's output open; its reader was abandoned)"
            }
        }
        return ShellResult(
            exitCode: (timedOut || waitFailed) ? -1 : exitCode(fromWaitStatus: waitStatus),
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: stderrText
        )
    }

    /// Read a pipe until EOF, delivering each chunk as it arrives.
    /// `availableData` blocks until at least one byte or EOF (empty Data).
    private static func drain(_ handle: FileHandle, into append: (Data) -> Void) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            append(chunk)
        }
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
                                            _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R?) -> R? {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        cStrings.reserveCapacity(strings.count)
        for s in strings {
            guard let c = strdup(s) else {
                cStrings.forEach { free($0) }
                return nil
            }
            cStrings.append(c)
        }
        defer { cStrings.forEach { free($0) } }
        var pointers = cStrings.map { Optional($0) }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return nil }
            return body(base)
        }
    }

    // MARK: Binary lookup

    private static let cacheLock = NSLock()
    private static var executableCache: [String: String] = [:]
    private static var missCache: [String: Date] = [:]
    /// How long a "not found" result is trusted before re-checking. Short enough
    /// that installing a missing tool still takes effect quickly, long enough that
    /// the 10s status timer doesn't respawn a login `zsh -lc` on every tick when a
    /// tool (e.g. git) is genuinely missing.
    private static let missCacheTTL: TimeInterval = 60

    /// Absolute path for `command`: the developer PATH and inherited PATH are
    /// checked directly, then — for unusual setups (MacPorts, nix) — a login
    /// shell is asked once via `command -v`. Hits are cached permanently; misses
    /// for a short TTL, so installing a missing tool works without a relaunch.
    static func resolveExecutable(_ command: String) -> String? {
        if command.contains("/") { return command }   // explicit path — use as-is

        cacheLock.lock()
        if let cached = executableCache[command] {
            cacheLock.unlock()
            return cached
        }
        if let missedAt = missCache[command], Date().timeIntervalSince(missedAt) < missCacheTTL {
            cacheLock.unlock()
            return nil
        }
        cacheLock.unlock()

        guard let found = findExecutable(command) else {
            cacheLock.lock()
            missCache[command] = Date()
            cacheLock.unlock()
            return nil
        }
        cacheLock.lock()
        executableCache[command] = found
        missCache.removeValue(forKey: command)
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
            killGracePeriod: 1,
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
