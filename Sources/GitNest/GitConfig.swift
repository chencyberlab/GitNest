import Foundation

/// One GitHub account as described by the local multi-account setup.
struct Account: Identifiable, Hashable, Sendable {
    var id: String { alias }
    let alias: String   // account key / ssh-alias suffix, e.g. "work"
    let name: String    // git user.name
    let email: String   // git user.email
    let folder: String  // absolute path to this account's repo folder
    var sshHost: String { "github-\(alias)" }
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

        var accounts: [Account] = []
        var pendingFolder: String?

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let folder = matchGitdir(line) {
                pendingFolder = folder
            } else if line.lowercased().hasPrefix("path"),
                      let folder = pendingFolder,
                      let cfgPath = value(line) {
                if let account = loadAccountFile(expand(cfgPath), folder: expand(folder)) {
                    accounts.append(account)
                }
                pendingFolder = nil
            }
        }
        return accounts
    }

    // [includeIf "gitdir:~/path/"]
    private static func matchGitdir(_ line: String) -> String? {
        guard line.hasPrefix("[includeIf"), let r = line.range(of: "gitdir:") else { return nil }
        let after = line[r.upperBound...]
        guard let endQuote = after.firstIndex(of: "\"") else { return nil }
        return String(after[..<endQuote])
    }

    private static func loadAccountFile(_ path: String, folder: String) -> Account? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var name = "", email = "", alias = ""

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("name"), let v = value(line) {
                name = v
            } else if line.lowercased().hasPrefix("email"), let v = value(line) {
                email = v
            } else if line.hasPrefix("[url"), let r = line.range(of: "git@github-") {
                let after = line[r.upperBound...]
                if let colon = after.firstIndex(of: ":") { alias = String(after[..<colon]) }
            }
        }

        if alias.isEmpty { alias = folderAlias(folder) ?? name }   // fall back to folder convention
        guard !alias.isEmpty else { return nil }
        return Account(alias: alias, name: name, email: email, folder: folder)
    }

    private static func value(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        return String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
    }

    // .../github_<alias>/  ->  <alias>
    private static func folderAlias(_ folder: String) -> String? {
        let last = (folder as NSString).lastPathComponent
        return last.hasPrefix("github_") ? String(last.dropFirst("github_".count)) : nil
    }
}
