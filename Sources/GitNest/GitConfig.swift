import Foundation

/// One GitHub account as described by the local multi-account setup.
struct Account: Identifiable, Hashable, Sendable {
    var id: String { alias }
    let alias: String   // account key / ssh-alias suffix, e.g. "work"
    let name: String    // git user.name
    let email: String   // git user.email
    let folder: String  // absolute path to this account's repo folder
    var sshHost: String { "github-\(alias)" }
    /// Pre-lowercased fields used by the search matcher.
    let searchableHaystacks: [String]

    init(alias: String, name: String, email: String, folder: String) {
        self.alias = alias
        self.name = name
        self.email = email
        self.folder = folder
        self.searchableHaystacks = [alias, name, email, folder].map { $0.lowercased() }
    }
}

/// Discovers accounts by reading ~/.gitconfig `includeIf "gitdir:…"` rules and the
/// per-account config files they point to (which carry name/email + the url alias).
enum GitConfig {
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func loadAccounts() -> [Account] {
        let gitconfig = expand("~/.gitconfig")
        guard let text = try? String(contentsOfFile: gitconfig, encoding: .utf8) else { return [] }
        return loadAccounts(from: text) { path in
            try? String(contentsOfFile: path, encoding: .utf8)
        }
    }

    static func loadAccounts(from text: String, accountConfig: (String) -> String?) -> [Account] {
        var accounts: [Account] = []
        var seenAliases: Set<String> = []
        var pendingFolder: String?

        for raw in text.components(separatedBy: .newlines) {
            let line = strippedLine(raw)
            guard !line.isEmpty else { continue }
            if let folder = matchGitdir(line) {
                pendingFolder = folder
            } else if line.hasPrefix("[") {
                pendingFolder = nil
            } else if key(line)?.caseInsensitiveCompare("path") == .orderedSame,
                      let folder = pendingFolder,
                      let cfgPath = value(line) {
                // Two `includeIf` rules can point at the same per-account config (one
                // account, two folders), which yields the same alias twice. The app
                // keys everything — Account.id, repoCache, ForEach — on alias, so a
                // duplicate would collide caches and trap ForEach. Keep the first.
                if let accountText = accountConfig(expand(cfgPath)),
                   let account = loadAccount(from: accountText, folder: expand(folder)),
                   seenAliases.insert(account.alias).inserted {
                    accounts.append(account)
                }
                pendingFolder = nil
            }
        }
        return accounts
    }

    // [includeIf "gitdir:~/path/"] — also the case-insensitive [includeIf "gitdir/i:…"]
    private static func matchGitdir(_ line: String) -> String? {
        guard line.range(of: "[includeIf", options: [.caseInsensitive, .anchored]) != nil else { return nil }
        // Check `gitdir/i:` first since it's a longer, more specific marker.
        guard let r = line.range(of: "gitdir/i:", options: .caseInsensitive)
                ?? line.range(of: "gitdir:", options: .caseInsensitive) else { return nil }
        let after = line[r.upperBound...]
        guard let endQuote = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<endQuote])
    }

    private static func loadAccount(from text: String, folder: String) -> Account? {
        var name = "", email = "", alias = ""

        for raw in text.components(separatedBy: .newlines) {
            let line = strippedLine(raw)
            let configKey = key(line)
            if configKey?.caseInsensitiveCompare("name") == .orderedSame, let v = value(line) {
                name = v
            } else if configKey?.caseInsensitiveCompare("email") == .orderedSame, let v = value(line) {
                email = v
            } else if line.range(of: "[url", options: [.caseInsensitive, .anchored]) != nil,
                      let r = line.range(of: "git@github-", options: .caseInsensitive) {
                let after = line[r.upperBound...]
                if let colon = after.firstIndex(of: ":") { alias = String(after[..<colon]) }
            }
        }

        if alias.isEmpty { alias = folderAlias(folder) ?? name }   // fall back to folder convention
        guard !alias.isEmpty else { return nil }
        return Account(alias: alias, name: name, email: email, folder: folder)
    }

    private static func key(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        return String(line[..<eq]).trimmingCharacters(in: .whitespaces)
    }

    private static func value(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let raw = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        return unescapeGitConfigValue(raw)
    }

    /// Unquote and unescape a git config value the same way `git config` does.
    /// `\"` becomes `"`, `\\` becomes `\`, `\n` becomes newline, `\t` becomes tab,
    /// `\b` becomes backspace, and surrounding quotes are removed. Keeps other
    /// backslash sequences literal so that unusual but valid values round-trip
    /// through `git config` writes.
    static func unescapeGitConfigValue(_ raw: String) -> String {
        guard raw.count >= 2, raw.first == "\"", raw.last == "\"" else { return raw }
        var value = raw
        value.removeFirst()
        value.removeLast()

        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            let char = value[index]
            if char == "\\", value.index(after: index) < value.endIndex {
                let next = value[value.index(after: index)]
                switch next {
                case "\"":
                    output.append("\"")
                case "\\":
                    output.append("\\")
                case "n":
                    output.append("\n")
                case "t":
                    output.append("\t")
                case "b":
                    output.append("\u{08}")
                default:
                    // Unknown escape: git keeps the backslash + char literally.
                    output.append(char)
                    output.append(next)
                }
                index = value.index(after: value.index(after: index))
            } else {
                output.append(char)
                index = value.index(after: index)
            }
        }
        return output
    }

    /// Remove inline comments (`#` or `;`) only outside quoted strings, then trim.
    /// Git config treats `#` and `;` as comment starters, but values like
    /// `insteadOf = https://github.com/` must keep any `#` inside quoted URLs.
    private static func strippedLine(_ raw: String) -> String {
        var result = ""
        var inQuotes = false
        var escaped = false
        for char in raw {
            if escaped {
                result.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                result.append(char)
                escaped = true
                continue
            }
            if char == "\"" { inQuotes.toggle() }
            if !inQuotes && (char == "#" || char == ";") { break }
            result.append(char)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // .../github-<alias>/ or .../github_<alias>/  ->  <alias>
    // Both separators are accepted: the README documents the hyphen form
    // (~/Developer/github-work/) while earlier setups used an underscore.
    private static func folderAlias(_ folder: String) -> String? {
        let last = (folder as NSString).lastPathComponent
        for prefix in ["github-", "github_"] where last.hasPrefix(prefix) {
            let alias = String(last.dropFirst(prefix.count))
            return alias.isEmpty ? nil : alias
        }
        return nil
    }
}
