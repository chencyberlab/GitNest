import Foundation

/// Orchestrates adding a new GitHub account to the local multi-account setup:
/// a dedicated SSH key, the `~/.ssh/config` host alias, the global `includeIf`
/// rule, the per-account `~/.gitconfig-<alias>`, and the local repo folder.
///
/// Safety rules, enforced everywhere here:
///  • every file edit timestamp-backs-up the original first,
///  • an existing SSH key is reused, never overwritten,
///  • edits are idempotent (re-running for the same account is a no-op/refresh),
///  • `git config` is used for gitconfig so the files stay syntactically valid.
enum AccountSetup {
    // MARK: Paths

    static func sshDir() -> String { ("~/.ssh" as NSString).expandingTildeInPath }
    static func keyPath(alias: String) -> String {
        (sshDir() as NSString).appendingPathComponent("id_\(alias)")
    }
    static func pubKeyPath(alias: String) -> String { keyPath(alias: alias) + ".pub" }
    static func sshConfigPath() -> String { (sshDir() as NSString).appendingPathComponent("config") }
    static func gitconfigPath() -> String { ("~/.gitconfig" as NSString).expandingTildeInPath }
    static func accountGitconfigPath(alias: String) -> String {
        ("~/.gitconfig-\(alias)" as NSString).expandingTildeInPath
    }

    /// True when `a` and `b` are the same folder or one is nested inside the other.
    /// Uses standardized URLs so symlinks and trailing slashes don't hide overlaps.
    static func foldersOverlap(_ a: String, _ b: String) -> Bool {
        let pathA = normalizedFolderPath(a)
        let pathB = normalizedFolderPath(b)
        return pathA == pathB || pathA.hasPrefix(pathB + "/") || pathB.hasPrefix(pathA + "/")
    }

    /// Expand `~`, resolve symlinks, and standardize — same normalization used for
    /// project-init safety checks so overlap detection can't miss symlink aliases.
    static func normalizedFolderPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: Identity (read from gh after sign-in)

    struct Identity: Sendable {
        let login: String
        let id: Int
        let name: String?
        var alias: String { login.lowercased() }
        var displayName: String { name.nilIfEmpty ?? login }
        /// GitHub's private no-reply commit address — safe to commit with.
        var noreplyEmail: String { "\(id)+\(login)@users.noreply.github.com" }
    }

    struct SSHConfigResult: Sendable {
        let block: String
        let backupPath: String?

        var wroteBlock: Bool { !block.isEmpty }
    }

    struct GitConfigWriteResult: Sendable {
        let accountGitconfigBackupPath: String?
        let globalGitconfigBackupPath: String?
    }

    struct Verification: Sendable, Equatable {
        let expectedAlias: String
        let sshText: String
        let sshLogin: String?
        let ghLogin: String?
        let restoreWarning: String?

        var sshOK: Bool { loginMatches(sshLogin, expectedAlias: expectedAlias) }
        var ghOK: Bool { loginMatches(ghLogin, expectedAlias: expectedAlias) }
        var ok: Bool { sshOK && ghOK }
    }

    /// Read the currently active gh account's login/id/name (call right after sign-in).
    static func currentIdentity() -> Result<Identity, CommandError> {
        let res = Shell.run(["gh", "api", "user", "--jq", "{login: .login, id: .id, name: .name}"])
        guard res.ok, let data = res.stdout.data(using: .utf8) else {
            return .failure(CommandError(message: short(res)))
        }
        struct U: Decodable { let login: String; let id: Int; let name: String? }
        guard let u = try? JSONDecoder().decode(U.self, from: data) else {
            return .failure(CommandError(message: "could not parse gh user info"))
        }
        return .success(Identity(login: u.login, id: u.id, name: u.name))
    }

    // MARK: SSH key

    /// Create a dedicated ed25519 key for `alias` if one doesn't already exist.
    /// Returns the public key text and whether it was newly created. Never
    /// overwrites an existing key (it's reused, since it may already be on GitHub).
    static func ensureKey(alias: String, comment: String) -> Result<(publicKey: String, created: Bool), CommandError> {
        let dir = sshDir()
        _ = Shell.run(["mkdir", "-p", dir])
        _ = Shell.run(["chmod", "700", dir])
        let key = keyPath(alias: alias)
        var created = false
        if !FileManager.default.fileExists(atPath: key) {
            // -N "" = no passphrase: the key is protected by its file permissions
            // alone. There's no passphrase for the keychain (UseKeychain) to store,
            // so the keychain adds nothing here — a deliberate tradeoff for
            // unattended, per-account git over SSH.
            let res = Shell.run(["ssh-keygen", "-t", "ed25519", "-C", comment, "-f", key, "-N", ""])
            guard res.ok else { return .failure(CommandError(message: short(res))) }
            created = true
        }
        // Enforce 0600 on the private key whether we just created it or are reusing
        // a pre-existing one — a key the app didn't create could have looser perms,
        // and ssh refuses a group/world-readable key.
        _ = Shell.run(["chmod", "600", key])
        guard let pub = try? String(contentsOfFile: pubKeyPath(alias: alias), encoding: .utf8) else {
            return .failure(CommandError(message: "could not read public key at \(pubKeyPath(alias: alias))"))
        }
        return .success((pub.trimmingCharacters(in: .whitespacesAndNewlines), created))
    }

    // MARK: Config writers

    /// Append a `Host github-<alias>` block to `~/.ssh/config` if absent (backs up
    /// first). Returns the block written, or "" when it was already configured.
    static func ensureSSHConfig(alias: String) -> Result<SSHConfigResult, CommandError> {
        let host = "github-\(alias)"
        let path = sshConfigPath()
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if containsHostEntry(host: host, in: existing) {
            return .success(SSHConfigResult(block: "", backupPath: nil))   // already present — leave it alone
        }
        let backupPath: String?
        do {
            backupPath = try backup(path)
        } catch {
            return .failure(CommandError(message: "could not back up ~/.ssh/config: \(error.localizedDescription)"))
        }
        let block = """
        Host \(host)
            HostName github.com
            User git
            IdentityFile ~/.ssh/id_\(alias)
            IdentitiesOnly yes
            AddKeysToAgent yes
            UseKeychain yes
        """
        let newText = existing.isEmpty ? block + "\n" : existing.trimmingTrailingNewlines() + "\n\n" + block + "\n"
        guard writePrivately(newText, to: path) else {
            return .failure(CommandError(message: "could not write ~/.ssh/config"))
        }
        return .success(SSHConfigResult(block: block, backupPath: backupPath))
    }

    /// Write the per-account gitconfig + global `includeIf` rule and create the
    /// folder. Backs up `~/.gitconfig` first; uses `git config` so files stay valid.
    /// Pass the folders of any already-configured accounts so the new folder cannot
    /// silently overlap an existing one (defense in depth: the UI also checks this).
    static func writeGitConfig(alias: String,
                               name: String,
                               email: String,
                               folder: String,
                               existingAccountFolders: [String] = []) -> Result<GitConfigWriteResult, CommandError> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .failure(CommandError(message: "user.name cannot be empty"))
        }
        guard !trimmedEmail.isEmpty else {
            return .failure(CommandError(message: "user.email cannot be empty"))
        }

        let accountCfg = accountGitconfigPath(alias: alias)
        let host = "github-\(alias)"
        let expandedFolder = (folder as NSString).expandingTildeInPath

        for existing in existingAccountFolders {
            let expandedExisting = (existing as NSString).expandingTildeInPath
            if foldersOverlap(expandedFolder, expandedExisting) {
                return .failure(CommandError(
                    message: "Chosen folder overlaps with an existing account folder: \(expandedExisting)"
                ))
            }
        }

        let accountBackup: String?
        let globalBackup: String?
        do {
            accountBackup = try backup(accountCfg)
            globalBackup = try backup(gitconfigPath())
        } catch {
            return .failure(CommandError(message: "could not create config backup: \(error.localizedDescription)"))
        }

        let folderExisted = FileManager.default.fileExists(atPath: expandedFolder)
        let mk = Shell.run(["mkdir", "-p", expandedFolder])
        guard mk.ok else { return .failure(CommandError(message: short(mk))) }

        // Any failure past this point restores both config files to their pre-edit
        // state (and removes a folder this call just created), so a failed run is a
        // true no-op rather than a half-configured account. This is what makes the
        // remove-then-add of the includeIf rule below safe: if the add fails,
        // restoring the global config brings the old rule back instead of leaving
        // the account loaded by no folder at all.
        func fail(_ r: ShellResult) -> Result<GitConfigWriteResult, CommandError> {
            restore(accountBackup, to: accountCfg)
            restore(globalBackup, to: gitconfigPath())
            if !folderExisted,
               let contents = try? FileManager.default.contentsOfDirectory(atPath: expandedFolder),
               contents.isEmpty {
                try? FileManager.default.removeItem(atPath: expandedFolder)
            }
            return .failure(CommandError(message: short(r)))
        }

        for kv in [("user.name", trimmedName), ("user.email", trimmedEmail)] {
            let r = Shell.run(["git", "config", "--file", accountCfg, kv.0, kv.1])
            guard r.ok else { return fail(r) }
        }

        // url."git@github-<alias>:".insteadOf = https://github.com/  and  git@github.com:
        // Reset then add both, so re-running stays clean (no duplicate lines).
        let urlKey = "url.git@\(host):.insteadOf"
        _ = Shell.run(["git", "config", "--file", accountCfg, "--unset-all", urlKey])
        for value in ["https://github.com/", "git@github.com:"] {
            let r = Shell.run(["git", "config", "--file", accountCfg, "--add", urlKey, value])
            guard r.ok else { return fail(r) }
        }

        // Drop any existing includeIf rules that already point at this account's
        // config. Re-running the wizard with a *different* folder would otherwise
        // leave the old `includeIf.gitdir:<old-folder>` rule behind, so both the
        // old and new folder would load this account — a silent accumulation of
        // stale rules. Removing first then re-adding guarantees exactly one rule.
        removeIncludeRules(pointingTo: accountCfg)

        // Global includeIf → per-account config. Store portable (~/) paths so the
        // rule survives moving to another Mac.
        var gitdir = portablePath(expandedFolder)
        if !gitdir.hasSuffix("/") { gitdir += "/" }
        let includeKey = "includeIf.gitdir:\(gitdir).path"
        let inc = Shell.run(["git", "config", "--global", includeKey, portablePath(accountCfg)])
        guard inc.ok else { return fail(inc) }

        return .success(GitConfigWriteResult(accountGitconfigBackupPath: accountBackup,
                                             globalGitconfigBackupPath: globalBackup))
    }

    // MARK: Verify

    /// Verify the new account end-to-end: SSH greeting + active gh login.
    ///
    /// `gh auth switch` changes global on-disk state (the active account), so this
    /// captures whatever account was active first and restores it afterward — a
    /// stray call must not leave the user's active `gh` account flipped to the one
    /// being verified. (Callers also wrap this in `serializedPreservingActiveAccount`;
    /// restoring here too makes the side effect impossible to leak.)
    static func verify(alias: String) -> Verification {
        let greeting = GitHub.sshGreeting(host: "github-\(alias)")
        let original = GitHub.currentLogin()
        _ = Shell.run(["gh", "auth", "switch", "-u", alias])
        let who = Shell.run(["gh", "api", "user", "--jq", ".login"])
        let login = who.ok ? who.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        var restoreWarningText: String?
        if let original, !original.isEmpty, original.caseInsensitiveCompare(alias) != .orderedSame {
            let restore = GitHub.switchTo(original)
            restoreWarningText = restoreWarning(afterSwitchResult: restore, restoring: original)
        }
        return verification(expectedAlias: alias, sshText: greeting, ghLogin: login, restoreWarning: restoreWarningText)
    }

    // MARK: Helpers

    /// Write `text` to `path` so the file is mode 0600 the instant it appears —
    /// never momentarily world-readable, and without downgrading a file that was
    /// already hardened. A 0600 temp file is created in the same directory and
    /// `rename(2)`d over the destination (atomic, replaces in place).
    static func writePrivately(_ text: String, to path: String) -> Bool {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = (dir as NSString).appendingPathComponent(".gitnest-tmp-\(UUID().uuidString.prefix(8))")
        guard fm.createFile(atPath: tmp,
                            contents: Data(text.utf8),
                            attributes: [.posixPermissions: 0o600]) else { return false }
        let renamed = tmp.withCString { t in path.withCString { p in rename(t, p) } }
        if renamed != 0 {
            try? fm.removeItem(atPath: tmp)
            return false
        }
        return true
    }

    /// Restore a file from a backup taken by `backup(_:)`. When `backup` is nil the
    /// file didn't exist before this run, so its creation is undone instead.
    static func restore(_ backup: String?, to path: String) {
        let fm = FileManager.default
        guard let backup else {
            try? fm.removeItem(atPath: path)
            return
        }
        // Copy to a sibling temp then rename over `path`, so there is never a window
        // where `path` is missing — a concurrent `git` reading ~/.gitconfig (e.g. a
        // background status sweep) could otherwise transiently fail.
        let tmp = path + ".gitnest-restore-\(UUID().uuidString.prefix(8))"
        do {
            try? fm.removeItem(atPath: tmp)
            try fm.copyItem(atPath: backup, toPath: tmp)
            if tmp.withCString({ t in path.withCString { p in rename(t, p) } }) != 0 {
                try? fm.removeItem(atPath: tmp)
            }
        } catch {
            try? fm.removeItem(atPath: tmp)
        }
    }

    /// Timestamped backup before editing a file (no-op when the file is absent).
    @discardableResult
    static func backup(_ path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var dest = backupDestination(for: path)
        while FileManager.default.fileExists(atPath: dest) {
            dest = backupDestination(for: path)
        }
        try FileManager.default.copyItem(atPath: path, toPath: dest)
        return dest
    }

    static func backupDestination(for path: String,
                                  timestamp: String = backupFormatter.string(from: Date()),
                                  nonce: String = UUID().uuidString) -> String {
        "\(path).backup-\(timestamp)-\(nonce.prefix(8))"
    }

    static func containsHostEntry(host: String, in config: String) -> Bool {
        for raw in config.components(separatedBy: .newlines) {
            // Drop inline comments and surrounding whitespace.
            let uncommented = raw.split(separator: "#", maxSplits: 1).first ?? ""
            let line = uncommented.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.first?.caseInsensitiveCompare("Host") == .orderedSame else { continue }
            for pattern in parts.dropFirst() {
                let trimmed = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if hostMatchesPattern(host: host, pattern: trimmed) {
                    return true
                }
            }
        }
        return false
    }

    /// True when `host` matches an SSH `Host` pattern. Patterns use `*` (any string)
    /// and `?` (one character), matching case-insensitively. An exact host name also
    /// matches. This prevents the wizard from appending a duplicate block when the
    /// user already has a wildcard such as `Host github-*`.
    ///
    /// A pattern made up *only* of wildcards (e.g. the near-universal `Host *`
    /// catch-all macOS users keep for `AddKeysToAgent`/`UseKeychain`) is NOT treated
    /// as a match: it doesn't configure this host's `HostName`/`IdentityFile`, so the
    /// wizard must still write its dedicated `Host github-<alias>` block. Requiring at
    /// least one literal character keeps `github-*` matching while excluding `*`/`?`.
    static func hostMatchesPattern(host: String, pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        // Comma-separated alternates on one Host line (OpenSSH 7.6+). They are
        // evaluated left-to-right; the final matching pattern wins, so a later
        // negated pattern can override an earlier positive one.
        if trimmed.contains(",") {
            let parts = trimmed.split(separator: ",").map(String.init)
            var lastMatchWasPositive = false
            for part in parts {
                let cleanPart = part.trimmingCharacters(in: .whitespaces)
                let isNegated = cleanPart.hasPrefix("!")
                let inner = isNegated ? String(cleanPart.dropFirst()) : cleanPart
                if hostMatchesPattern(host: host, pattern: inner) {
                    lastMatchWasPositive = !isNegated
                }
            }
            return lastMatchWasPositive
        }

        // OpenSSH negation: `!pattern` matches when the inner pattern does not.
        if trimmed.hasPrefix("!") {
            return !hostMatchesPattern(host: host, pattern: String(trimmed.dropFirst()))
        }

        if trimmed.caseInsensitiveCompare(host) == .orderedSame { return true }
        guard trimmed.contains("*") || trimmed.contains("?") else { return false }
        guard trimmed.contains(where: { $0 != "*" && $0 != "?" }) else { return false }

        var regex = ""
        for char in trimmed {
            switch char {
            case "*":
                regex.append(".*")
            case "?":
                regex.append(".")
            case "\\", ".", "+", "[", "]", "{", "}", "(", ")", "^", "$", "|":
                regex.append("\\" + String(char))
            default:
                regex.append(char)
            }
        }
        guard let re = try? NSRegularExpression(pattern: "^" + regex + "$", options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(location: 0, length: (host as NSString).length)
        return re.firstMatch(in: host, options: [], range: range) != nil
    }

    static func sshLogin(from greeting: String) -> String? {
        let nsText = greeting as NSString
        let pattern = #"Hi\s+([^!]+)!"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: greeting, options: [], range: range),
              match.numberOfRanges > 1 else { return nil }
        return nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func verification(expectedAlias: String,
                             sshText: String,
                             ghLogin: String?,
                             restoreWarning: String? = nil) -> Verification {
        Verification(expectedAlias: expectedAlias,
                     sshText: sshText,
                     sshLogin: sshLogin(from: sshText),
                     ghLogin: ghLogin,
                     restoreWarning: restoreWarning)
    }

    static func restoreWarning(afterSwitchResult result: ShellResult, restoring alias: String) -> String? {
        guard !result.ok else { return nil }
        let detail = short(result)
        let reason = detail.isEmpty ? "unknown error" : detail
        return "could not restore active gh account to \(alias): \(reason)"
    }

    static func loginMatches(_ login: String?, expectedAlias: String) -> Bool {
        guard let login, !login.isEmpty else { return false }
        return login.caseInsensitiveCompare(expectedAlias) == .orderedSame
    }

    private static let backupFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Rewrite an absolute path under the home dir to a portable `~/…` form.
    static func portablePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Unset every global `includeIf.gitdir:*` rule whose value resolves to
    /// `accountCfg`. Quiet when there are none (`--get-regexp` exits non-zero).
    private static func removeIncludeRules(pointingTo accountCfg: String) {
        let listed = Shell.run(["git", "config", "--global", "-z", "--get-regexp", "gitdir:"])
        guard listed.ok else { return }
        for key in includeKeysPointing(to: accountCfg, inNullDelimited: listed.stdout) {
            _ = Shell.run(["git", "config", "--global", "--unset-all", key])
        }
    }

    /// Canonical `includeIf.gitdir:*.path` keys in `output` whose value points at
    /// `target`. `output` is the NUL-delimited `key\nvalue` stream produced by
    /// `git config -z --get-regexp`; tilde paths on either side are expanded so a
    /// portable `~/.gitconfig-x` matches the same absolute file.
    static func includeKeysPointing(to target: String, inNullDelimited output: String) -> [String] {
        let wanted = (target as NSString).expandingTildeInPath
        var keys: [String] = []
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let newline = record.firstIndex(of: "\n") else { continue }
            let key = String(record[..<newline])
            let value = String(record[record.index(after: newline)...])
            let lowerKey = key.lowercased()
            guard (lowerKey.hasPrefix("includeif.gitdir:") || lowerKey.hasPrefix("includeif.gitdir/i:")),
                  lowerKey.hasSuffix(".path") else { continue }
            if (value as NSString).expandingTildeInPath == wanted { keys.append(key) }
        }
        return keys
    }

    private static func short(_ r: ShellResult) -> String {
        (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var s = self
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        return s
    }
}
