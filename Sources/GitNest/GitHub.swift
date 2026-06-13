import Foundation

/// A repository as returned by GitHub repository list/view calls.
struct Repo: Identifiable, Hashable, Sendable, Decodable {
    let name: String
    let nameWithOwner: String
    let description: String?
    let visibility: String
    let updatedAt: String?
    let url: String
    var id: String { nameWithOwner }

    /// Owner login parsed from `nameWithOwner` (the part before the slash).
    var owner: String { String(nameWithOwner.prefix { $0 != "/" }) }
}

/// A repo as returned by the REST `user/repos` endpoint (used for collaborator
/// repos, which `gh repo list <owner>` does not include). Mapped into `Repo`.
private struct RestRepo: Decodable {
    let name: String
    let full_name: String
    let description: String?
    let visibility: String?
    let `private`: Bool?
    let updated_at: String?
    let html_url: String

    var asRepo: Repo {
        let vis = visibility ?? ((`private` ?? false) ? "private" : "public")
        return Repo(name: name, nameWithOwner: full_name, description: description,
                    visibility: vis, updatedAt: updated_at, url: html_url)
    }
}

private struct RepoViewPayload: Decodable {
    struct Parent: Decodable {
        let nameWithOwner: String
    }

    let name: String
    let nameWithOwner: String
    let description: String?
    let visibility: String
    let updatedAt: String?
    let url: String
    let parent: Parent?

    var details: RepoViewDetails {
        RepoViewDetails(
            repo: Repo(name: name,
                       nameWithOwner: nameWithOwner,
                       description: description,
                       visibility: visibility,
                       updatedAt: updatedAt,
                       url: url),
            parentNameWithOwner: parent?.nameWithOwner
        )
    }
}

struct RepoViewDetails {
    let repo: Repo
    let parentNameWithOwner: String?

    func isFork(of source: RepoReference) -> Bool {
        guard let parentNameWithOwner else { return false }
        return parentNameWithOwner.caseInsensitiveCompare(source.nameWithOwner) == .orderedSame
    }
}

/// Error carrying a human-readable message from a failed `gh`/`git` call.
struct GitHubError: Error, Sendable {
    let message: String
}

/// A reference to a GitHub repository extracted from user input such as a URL
/// or an `owner/repo` shorthand. Keeps the original text for display/logging.
struct RepoReference: Sendable {
    let owner: String
    let repo: String
    let raw: String

    var nameWithOwner: String { "\(owner)/\(repo)" }
}

extension RepoReference {
    /// Parses a GitHub repository reference from common formats:
    ///   - https://github.com/owner/repo
    ///   - https://github.com/owner/repo.git
    ///   - http://github.com/owner/repo
    ///   - github.com/owner/repo
    ///   - git@github.com:owner/repo.git
    ///   - owner/repo
    /// Returns `nil` when the input is empty, not GitHub, or not exactly an owner/repo pair.
    static func parse(_ input: String) -> RepoReference? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let ssh = parseSSH(trimmed, raw: trimmed) {
            return ssh
        }

        if let web = parseWebURL(trimmed, raw: trimmed) {
            return web
        }

        return parseOwnerRepoShorthand(trimmed, raw: trimmed)
    }

    private static func parseSSH(_ input: String, raw: String) -> RepoReference? {
        if input.lowercased().hasPrefix("ssh://") {
            guard let components = URLComponents(string: input),
                  components.scheme?.lowercased() == "ssh",
                  components.host?.lowercased() == "github.com" else { return nil }
            return pair(fromPath: components.path, raw: raw)
        }

        guard let at = input.firstIndex(of: "@"),
              let colon = input[at...].firstIndex(of: ":"),
              at < colon else { return nil }

        let host = String(input[input.index(after: at)..<colon]).lowercased()
        guard host == "github.com" else { return nil }

        let path = String(input[input.index(after: colon)...])
        return pair(fromPath: path, raw: raw)
    }

    private static func parseWebURL(_ input: String, raw: String) -> RepoReference? {
        var candidate = input
        if candidate.lowercased().hasPrefix("github.com/") {
            candidate = "https://" + candidate
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.lowercased() == "github.com" else { return nil }

        return pair(fromPath: components.path, raw: raw)
    }

    private static func parseOwnerRepoShorthand(_ input: String, raw: String) -> RepoReference? {
        var candidate = input
        while candidate.hasSuffix("/") {
            candidate.removeLast()
        }
        return pair(fromPath: candidate, raw: raw)
    }

    private static func pair(fromPath path: String, raw: String) -> RepoReference? {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count == 2 else { return nil }

        let owner = components[0]
        let repo = stripGitSuffix(components[1])
        guard isValidOwner(owner), isValidRepo(repo) else { return nil }
        return RepoReference(owner: owner, repo: repo, raw: raw)
    }

    private static func stripGitSuffix(_ name: String) -> String {
        name.lowercased().hasSuffix(".git") ? String(name.dropLast(4)) : name
    }

    /// GitHub account and organization names are intentionally stricter than repo names.
    private static func isValidOwner(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 39 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard !name.hasPrefix("-"), !name.hasSuffix("-") else { return false }
        guard !name.contains("--") else { return false }
        return true
    }

    /// Repository names can contain dots, underscores, and repeated hyphens.
    /// The app still rejects path separators and empty/special names before calling git.
    private static func isValidRepo(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100 else { return false }
        guard name != ".", name != "..", name.lowercased() != ".git" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// Whether a cloned repo has been compared with its upstream remote during this
/// status pass. `.checked` means `git fetch` completed before ahead/behind was
/// parsed, so `behind` reflects GitHub now rather than stale local tracking refs.
enum RepoRemoteState: Sendable, Equatable {
    case unchecked
    case checked
    case noUpstream
    /// An upstream is configured, but its branch no longer exists on the remote
    /// (deleted or renamed) — `git status` reports it as `[gone]`.
    case upstreamGone
    case failed(String)

    var needsAttention: Bool {
        switch self {
        case .failed, .noUpstream, .upstreamGone: return true
        case .unchecked, .checked: return false
        }
    }
}

/// Local working-tree and upstream state for a cloned repo.
struct RepoStatus: Sendable, Equatable {
    var changedFiles: Int = 0   // uncommitted + untracked entries
    var ahead: Int = 0          // local commits not yet pushed
    var behind: Int = 0         // remote commits not yet pulled
    var hasUpstream: Bool = false
    var upstreamRemote: String?
    var remoteState: RepoRemoteState = .unchecked

    /// True when there is something the user would want to commit, pull, push,
    /// or fix before assuming the local clone matches GitHub.
    var needsAttention: Bool {
        changedFiles > 0 || ahead > 0 || behind > 0 || remoteState.needsAttention
    }

    var isDiverged: Bool { ahead > 0 && behind > 0 }
    var isCleanAndCurrent: Bool {
        changedFiles == 0 && ahead == 0 && behind == 0 && remoteState == .checked
    }

    static func parse(porcelainBranch output: String,
                      remoteState: RepoRemoteState = .unchecked) -> RepoStatus {
        var status = RepoStatus(remoteState: remoteState)
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("##") {
                status.hasUpstream = line.contains("...")
                status.upstreamRemote = upstreamRemote(from: line)
                if let open = line.lastIndex(of: "["),
                   let close = line.lastIndex(of: "]"), open < close {
                    for part in line[line.index(after: open)..<close].split(separator: ",") {
                        let token = part.trimmingCharacters(in: .whitespaces)
                        if token.hasPrefix("ahead "), let n = Int(token.dropFirst(6)) { status.ahead = n }
                        if token.hasPrefix("behind "), let n = Int(token.dropFirst(7)) { status.behind = n }
                        // "[gone]" — upstream configured but deleted on the remote.
                        // Without this, a gone branch would read as clean/current.
                        if token == "gone" { status.remoteState = .upstreamGone }
                    }
                }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                status.changedFiles += 1
            }
        }
        return status
    }

    private static func upstreamRemote(from branchLine: String) -> String? {
        guard let marker = branchLine.range(of: "...") else { return nil }
        let tail = branchLine[marker.upperBound...]
        guard let upstream = tail.split(whereSeparator: { $0 == " " || $0 == "[" }).first,
              let slash = upstream.firstIndex(of: "/") else { return nil }
        let remote = upstream[..<slash]
        return remote.isEmpty ? nil : String(remote)
    }
}

enum RepoVisibilityChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
    case `private`
    case `public`

    var id: String { rawValue }
    var ghFlag: String { self == .private ? "--private" : "--public" }
    var title: String { rawValue.capitalized }
}

struct ProjectInitPlan: Identifiable, Sendable {
    let id = UUID()
    let account: Account
    let sourcePath: String
    let workingPath: String
    let repoName: String
    let willCopy: Bool

    var sourceName: String {
        (sourcePath as NSString).lastPathComponent
    }

    var warningText: String {
        if willCopy {
            return """
            “\(sourceName)” will be copied to:
            \(workingPath)

            The copied folder will be initialized, pushed to \(account.alias)/\(repoName), and should be used for future development.
            """
        }

        return """
        “\(sourceName)” is already inside \(account.alias)’s GitHub folder.

        The app will initialize and push this folder in place to \(account.alias)/\(repoName).
        """
    }
}

/// Thin wrapper over the `gh` CLI (invisible plumbing) and `git` / `ssh`.
enum GitHub {
    /// Raw `gh auth status` text — shown so you can see which accounts are logged in.
    static func authStatus() -> ShellResult {
        Shell.run(["gh", "auth", "status"])
    }

    /// Starts GitHub CLI web login flow (opens browser) without SSH key prompts.
    static func authLoginWeb() -> ShellResult {
        Shell.run([
            "gh", "auth", "login",
            "--hostname", "github.com",
            "--web",
            "--git-protocol", "ssh",
            "--skip-ssh-key"
        ])
    }

    /// Same as `authLoginWeb`, but also copies one-time device code to clipboard.
    static func authLoginWebWithClipboard() -> ShellResult {
        Shell.run([
            "gh", "auth", "login",
            "--hostname", "github.com",
            "--web",
            "--clipboard",
            "--git-protocol", "ssh",
            "--skip-ssh-key"
        ])
    }

    /// Best-effort: make `owner` the active gh account so its private repos are visible.
    static func switchTo(_ owner: String) {
        _ = Shell.run(["gh", "auth", "switch", "-u", owner])
    }

    static func ensureActiveAccount(_ owner: String) -> ShellResult {
        let switched = Shell.run(["gh", "auth", "switch", "-u", owner])
        guard switched.ok else { return switched }

        let active = Shell.run(["gh", "api", "user", "--jq", ".login"])
        guard active.ok else { return active }

        let login = active.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard login.caseInsensitiveCompare(owner) == .orderedSame else {
            let displayLogin = login.isEmpty ? "unknown" : login
            return ShellResult(
                exitCode: 1,
                stdout: "",
                stderr: "gh active account is \(displayLogin), expected \(owner). Refusing to continue."
            )
        }

        return ShellResult(exitCode: 0, stdout: "gh active account: \(login)", stderr: "")
    }

    /// List every repo `owner` can see: the repos it owns, plus repos it has been
    /// added to as a collaborator (owned by someone else). Switches to that
    /// account first so private repos are visible.
    static func listRepos(owner: String) -> Result<[Repo], GitHubError> {
        listRepos(owner: owner,
                  ensureActive: ensureActiveAccount,
                  ownedRepos: ownedRepos,
                  collaboratorRepos: collaboratorRepos)
    }

    static func listRepos(owner: String,
                          ensureActive: (String) -> ShellResult,
                          ownedRepos: () -> Result<[Repo], GitHubError>,
                          collaboratorRepos: () -> [Repo]) -> Result<[Repo], GitHubError> {
        let accountCheck = ensureActive(owner)
        guard accountCheck.ok else {
            let detail = (accountCheck.stderr.isEmpty ? accountCheck.stdout : accountCheck.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GitHubError(message: detail.isEmpty
                ? "Could not switch to account \(owner)"
                : detail))
        }

        let ownedResult = ownedRepos()
        let owned: [Repo]
        switch ownedResult {
        case .success(let repos):
            owned = repos
        case .failure(let error):
            return .failure(error)
        }

        // Best-effort: fold in collaborator repos. A failure here must not break
        // the owned list, so we just ignore errors and return what we have.
        var byID: [String: Repo] = [:]
        for repo in owned { byID[repo.id] = repo }
        for repo in collaboratorRepos() where byID[repo.id] == nil { byID[repo.id] = repo }

        let merged = byID.values.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        return .success(merged)
    }

    /// Repos owned by the active account. Uses the REST endpoint instead of
    /// `gh repo list --limit ...` so it can paginate without a silent cap.
    private static func ownedRepos() -> Result<[Repo], GitHubError> {
        let res = Shell.run([
            "gh", "api", "user/repos?affiliation=owner&per_page=100",
            "--paginate", "--slurp",
        ])
        guard res.ok else {
            let msg = res.stderr.isEmpty ? res.stdout : res.stderr
            return .failure(GitHubError(message: msg.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard let repos = decodeSlurpedRestRepos(res.stdout) else {
            return .failure(GitHubError(message: "could not parse gh repo output"))
        }
        return .success(repos)
    }

    /// Repos the active account collaborates on but does not own. `affiliation=
    /// collaborator` excludes owned and org-member repos, so there is no overlap
    /// with `gh repo list`. Best-effort: returns [] on any error.
    private static func collaboratorRepos() -> [Repo] {
        let res = Shell.run([
            "gh", "api", "user/repos?affiliation=collaborator&per_page=100",
            "--paginate", "--slurp",
        ])
        guard res.ok, let repos = decodeSlurpedRestRepos(res.stdout) else { return [] }
        return repos
    }

    static func decodeSlurpedRestRepos(_ text: String) -> [Repo]? {
        guard let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let pages = try? decoder.decode([[RestRepo]].self, from: data) {
            return pages.flatMap { $0.map(\.asRepo) }
        }
        if let page = try? decoder.decode([RestRepo].self, from: data) {
            return page.map(\.asRepo)
        }
        return nil
    }

    /// Clone into the account's folder using an https URL — the per-folder rewrite
    /// rule routes it to the correct SSH key automatically.
    static func clone(repo: Repo, into folder: String) -> ShellResult {
        let url = "https://github.com/\(repo.nameWithOwner).git"
        let dest = (folder as NSString).appendingPathComponent(repo.name)
        if FileManager.default.fileExists(atPath: dest) {
            return ShellResult(exitCode: 1, stdout: "", stderr: "already exists: \(dest)")
        }
        return Shell.run(["git", "clone", url, dest])
    }

    /// Fork `source` into the active user's account and return the resulting repo.
    /// Does not clone; callers should clone separately using the returned `Repo`.
    /// Waits up to `timeoutSeconds` for the fork to become available via the API.
    static func fork(source: RepoReference,
                     intoAccount alias: String,
                     defaultBranchOnly: Bool = true,
                     timeoutSeconds: UInt64 = 60) -> Result<Repo, GitHubError> {
        let accountCheck = ensureActiveAccount(alias)
        guard accountCheck.ok else {
            let detail = (accountCheck.stdout + accountCheck.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GitHubError(message: detail.isEmpty ? "Could not switch to account \(alias)" : detail))
        }

        guard let currentUser = currentLogin() else {
            return .failure(GitHubError(message: "Could not determine the active GitHub user."))
        }

        var forkArgs = ["gh", "repo", "fork", source.nameWithOwner, "--clone=false"]
        if defaultBranchOnly {
            forkArgs.append("--default-branch-only")
        }

        let forkRes = Shell.run(forkArgs)
        let forkOutput = forkRes.stdout + "\n" + forkRes.stderr
        if !forkRes.ok {
            if let existing = existingFork(
                from: forkOutput,
                currentUser: currentUser,
                fallbackRepo: source.repo,
                source: source
            ) {
                return .success(existing)
            }

            let msg = (forkRes.stderr + forkRes.stdout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GitHubError(message: msg.isEmpty ? "fork failed" : msg))
        }

        let forkedNameWithOwner = forkedRepoNameWithOwner(
            from: forkOutput,
            currentUser: currentUser,
            fallbackRepo: source.repo
        )
        return waitForRepo(nameWithOwner: forkedNameWithOwner,
                           timeoutSeconds: timeoutSeconds)
    }

    static func forkedRepoNameWithOwner(from output: String,
                                        currentUser: String,
                                        fallbackRepo: String) -> String {
        forkedRepoNameCandidates(from: output, currentUser: currentUser, fallbackRepo: fallbackRepo)[0]
    }

    static func forkedRepoNameCandidates(from output: String,
                                         currentUser: String,
                                         fallbackRepo: String) -> [String] {
        let fallback = "\(currentUser)/\(fallbackRepo)"
        var seen: Set<String> = []
        var candidates: [String] = []
        for ref in repoReferences(in: output, owner: currentUser) {
            let key = ref.nameWithOwner.lowercased()
            guard seen.insert(key).inserted else { continue }
            candidates.append(ref.nameWithOwner)
        }
        if seen.insert(fallback.lowercased()).inserted {
            candidates.append(fallback)
        }
        return candidates
    }

    private static func existingFork(from output: String,
                                     currentUser: String,
                                     fallbackRepo: String,
                                     source: RepoReference) -> Repo? {
        for nameWithOwner in forkedRepoNameCandidates(from: output,
                                                      currentUser: currentUser,
                                                      fallbackRepo: fallbackRepo) {
            guard let details = repoViewDetails(nameWithOwner: nameWithOwner),
                  details.isFork(of: source) else { continue }
            return details.repo
        }
        return nil
    }

    private static func repoReferences(in text: String, owner: String) -> [RepoReference] {
        let pattern = #"(https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+(?:\.git)?|git@github\.com:[A-Za-z0-9-]+/[A-Za-z0-9._-]+(?:\.git)?|\b[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]+(?:\.git)?\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var refs: [RepoReference] = []
        for match in matches {
            let raw = nsText.substring(with: match.range(at: 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}<>\"'"))
            guard let ref = RepoReference.parse(raw),
                  ref.owner.caseInsensitiveCompare(owner) == .orderedSame else { continue }
            refs.append(ref)
        }
        return refs
    }

    /// Poll the GitHub API until the repo exists or the timeout elapses.
    private static func waitForRepo(nameWithOwner: String,
                                    timeoutSeconds: UInt64) -> Result<Repo, GitHubError> {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

        while Date() < deadline {
            if let repo = repoView(nameWithOwner: nameWithOwner) {
                return .success(repo)
            }
            // Not ready yet; wait before retrying.
            Thread.sleep(forTimeInterval: 1.0)
        }

        return .failure(GitHubError(message: """
            Fork created, but it didn't become available within \(timeoutSeconds) seconds. \
            You can try cloning \(nameWithOwner) manually once GitHub finishes the fork.
            """))
    }

    private static func repoView(nameWithOwner: String) -> Repo? {
        repoViewDetails(nameWithOwner: nameWithOwner)?.repo
    }

    private static func repoViewDetails(nameWithOwner: String) -> RepoViewDetails? {
        let view = Shell.run([
            "gh", "repo", "view", nameWithOwner,
            "--json", "name,nameWithOwner,description,visibility,updatedAt,url,parent"
        ])
        guard view.ok,
              let data = view.stdout.data(using: .utf8),
              let payload = try? JSONDecoder().decode(RepoViewPayload.self, from: data) else { return nil }
        return payload.details
    }

    /// Returns the login of the currently active `gh` account, or nil on failure.
    static func currentLogin() -> String? {
        let res = Shell.run(["gh", "api", "user", "--jq", ".login"])
        guard res.ok else { return nil }
        let login = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty ? nil : login
    }

    /// Add or update an `upstream` remote pointing back to the original source repo.
    static func setUpstream(source: RepoReference, at path: String) -> ShellResult {
        let url = "https://github.com/\(source.nameWithOwner).git"
        let existing = Shell.run(["git", "-C", path, "remote", "get-url", "upstream"])
        let result = existing.ok
            ? Shell.run(["git", "-C", path, "remote", "set-url", "upstream", url])
            : Shell.run(["git", "-C", path, "remote", "add", "upstream", url])

        guard result.ok else { return result }
        return ShellResult(exitCode: 0, stdout: "upstream -> \(url)", stderr: result.stderr)
    }

    static func pull(at path: String) -> ShellResult {
        Shell.run(["git", "-C", path, "pull"])
    }

    /// Dirty count + ahead/behind. With `refreshRemote`, first fetches the branch's
    /// upstream remote so behind/ahead are computed against current GitHub state.
    /// Returns nil when the path isn't a usable git repo.
    static func status(at path: String, refreshRemote: Bool = false) -> RepoStatus? {
        // --no-optional-locks (GIT_OPTIONAL_LOCKS=0): never take .git/index.lock for
        // this background poll, so it can't collide with a concurrent commit/add/pull
        // and produce a spurious "index.lock: File exists" error on either side.
        let res = Shell.run(["git", "--no-optional-locks", "-C", path, "status", "--porcelain", "--branch"])
        guard res.ok else { return nil }
        var status = RepoStatus.parse(porcelainBranch: res.stdout)
        guard refreshRemote else { return status }

        guard status.hasUpstream else {
            status.remoteState = .noUpstream
            return status
        }

        let remote = status.upstreamRemote ?? "origin"
        let fetch = Shell.run([
            "git", "--no-optional-locks", "-C", path,
            "fetch", "--prune", "--quiet", remote,
        ])
        guard fetch.ok else {
            status.remoteState = .failed(conciseMessage(fetch, fallback: "git fetch failed"))
            return status
        }

        let refreshed = Shell.run(["git", "--no-optional-locks", "-C", path, "status", "--porcelain", "--branch"])
        guard refreshed.ok else {
            status.remoteState = .failed(conciseMessage(refreshed, fallback: "git status failed after fetch"))
            return status
        }

        var next = RepoStatus.parse(porcelainBranch: refreshed.stdout, remoteState: .checked)
        if !next.hasUpstream { next.remoteState = .noUpstream }
        return next
    }

    private static func conciseMessage(_ result: ShellResult, fallback: String) -> String {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return fallback }
        return text
            .split(whereSeparator: \.isNewline)
            .prefix(2)
            .joined(separator: " ")
    }

    static func push(at path: String) -> ShellResult {
        Shell.run(["git", "-C", path, "push"])
    }

    static func origin(at path: String, matches repo: Repo) -> Bool {
        guard let existing = originURL(at: path) else { return false }
        return remoteLooksLike(existing, owner: repo.owner, repoName: repo.name)
    }

    static func originURL(at path: String) -> String? {
        let origin = Shell.run(["git", "-C", path, "remote", "get-url", "origin"])
        guard origin.ok else { return nil }
        let existing = origin.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? nil : existing
    }

    static func initAndPushProject(_ plan: ProjectInitPlan, visibility: RepoVisibilityChoice) -> ShellResult {
        var log: [String] = []
        let fm = FileManager.default
        let owner = plan.account.alias
        let repoFullName = "\(owner)/\(plan.repoName)"
        let remoteURL = "git@\(plan.account.sshHost):\(repoFullName).git"

        do {
            try fm.createDirectory(atPath: plan.account.folder, withIntermediateDirectories: true)
            if plan.willCopy {
                if fm.fileExists(atPath: plan.workingPath) {
                    return failure("destination already exists: \(plan.workingPath)", log)
                }
                try fm.copyItem(atPath: plan.sourcePath, toPath: plan.workingPath)
                log.append("Copied project to \(plan.workingPath)")
            } else {
                log.append("Using existing project folder \(plan.workingPath)")
            }
        } catch {
            return failure("copy failed: \(error.localizedDescription)", log)
        }

        let accountCheck = ensureActiveAccount(owner)
        guard accountCheck.ok else { return failure("gh account switch failed", log, accountCheck) }
        log.append(accountCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines))

        let origin = Shell.run(["git", "-C", plan.workingPath, "remote", "get-url", "origin"])
        if origin.ok, !plan.willCopy {
            let existing = origin.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard remoteLooksLike(existing, owner: owner, repoName: plan.repoName) else {
                return failure("origin already points somewhere else: \(existing)", log)
            }
        }

        let gitDir = (plan.workingPath as NSString).appendingPathComponent(".git")
        if !fm.fileExists(atPath: gitDir) {
            let initRes = Shell.run(["git", "-C", plan.workingPath, "init", "-b", "main"])
            if initRes.ok {
                log.append("Initialized git repository on main")
            } else {
                let fallback = Shell.run(["git", "-C", plan.workingPath, "init"])
                guard fallback.ok else { return failure("git init failed", log, fallback) }
                let branch = Shell.run(["git", "-C", plan.workingPath, "checkout", "-B", "main"])
                guard branch.ok else { return failure("creating main branch failed", log, branch) }
                log.append("Initialized git repository on main")
            }
        }

        let hasHead = Shell.run(["git", "-C", plan.workingPath, "rev-parse", "--verify", "HEAD"]).ok
        let add = Shell.run(["git", "-C", plan.workingPath, "add", "-A"])
        guard add.ok else { return failure("git add failed", log, add) }

        let staged = Shell.run(["git", "-C", plan.workingPath, "diff", "--cached", "--quiet"])
        if staged.exitCode == 1 || !hasHead {
            var commitArgs = ["git", "-C", plan.workingPath, "commit"]
            if !hasHead, staged.exitCode == 0 { commitArgs.append("--allow-empty") }
            commitArgs += ["-m", hasHead ? "Update before GitHub init" : "Initial commit"]
            let commit = Shell.run(commitArgs)
            guard commit.ok else { return failure("git commit failed", log, commit) }
            log.append(hasHead ? "Committed pending changes" : "Created initial commit")
        } else if staged.exitCode != 0 {
            return failure("checking staged changes failed", log, staged)
        }

        var branch = Shell.run(["git", "-C", plan.workingPath, "branch", "--show-current"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty {
            let checkout = Shell.run(["git", "-C", plan.workingPath, "checkout", "-B", "main"])
            guard checkout.ok else { return failure("selecting main branch failed", log, checkout) }
            branch = "main"
        }

        let create = Shell.run(["gh", "repo", "create", repoFullName, visibility.ghFlag])
        if create.ok {
            log.append("Created \(visibility.rawValue) GitHub repo \(repoFullName)")
        } else if repoView(nameWithOwner: repoFullName) != nil {
            log.append("GitHub repo \(repoFullName) already exists")
        } else {
            return failure("GitHub repo create failed", log, create)
        }

        if origin.ok {
            let setURL = Shell.run(["git", "-C", plan.workingPath, "remote", "set-url", "origin", remoteURL])
            guard setURL.ok else { return failure("setting origin failed", log, setURL) }
        } else {
            let addRemote = Shell.run(["git", "-C", plan.workingPath, "remote", "add", "origin", remoteURL])
            guard addRemote.ok else { return failure("adding origin failed", log, addRemote) }
        }

        let push = Shell.run(["git", "-C", plan.workingPath, "push", "-u", "origin", branch])
        guard push.ok else { return failure("git push failed", log, push) }
        log.append("Pushed \(branch) to \(repoFullName)")

        return ShellResult(exitCode: 0, stdout: log.joined(separator: "\n"), stderr: push.stderr)
    }

    /// Stage everything and commit. Returns the `add` result early if staging fails.
    static func commitAll(at path: String, message: String) -> ShellResult {
        let add = Shell.run(["git", "-C", path, "add", "-A"])
        guard add.ok else { return add }
        return Shell.run(["git", "-C", path, "commit", "-m", message])
    }

    /// `ssh -T git@github-<alias>` returns "Hi <name>!" on stderr — the auth check.
    /// BatchMode forbids interactive prompts (there's no terminal to answer on)
    /// and ConnectTimeout keeps a dead network from stalling the status sweep.
    static func sshGreeting(host: String) -> String {
        let res = Shell.run([
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-T", "git@\(host)",
        ])
        let text = res.stderr + "\n" + res.stdout
        if let line = text.components(separatedBy: .newlines).first(where: { $0.contains("Hi ") }) {
            return line.trimmingCharacters(in: .whitespaces)
        }
        let first = text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return first?.trimmingCharacters(in: .whitespaces) ?? "no response"
    }

    private static func failure(_ message: String, _ log: [String], _ result: ShellResult? = nil) -> ShellResult {
        let detail = result.map { ($0.stdout + $0.stderr).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let stderr = detail.isEmpty ? message : "\(message)\n\(detail)"
        return ShellResult(exitCode: result?.exitCode ?? 1, stdout: log.joined(separator: "\n"), stderr: stderr)
    }

    /// Whether an existing origin URL plausibly points at `owner/repoName` on
    /// GitHub, across https/ssh/host-alias forms. Internal for tests. Only a
    /// *trailing* ".git" is stripped — removing every occurrence would mangle
    /// names like "user.github.io" and reject their own correct origin.
    static func remoteLooksLike(_ remote: String, owner: String, repoName: String) -> Bool {
        guard let parsed = githubRemoteOwnerRepo(remote) else { return false }
        return parsed.owner.caseInsensitiveCompare(owner) == .orderedSame
            && parsed.repo.caseInsensitiveCompare(repoName) == .orderedSame
    }

    private static func githubRemoteOwnerRepo(_ remote: String) -> (owner: String, repo: String)? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }

        if let at = trimmed.firstIndex(of: "@"),
           let colon = trimmed[at...].firstIndex(of: ":"),
           at < colon {
            let host = String(trimmed[trimmed.index(after: at)..<colon]).lowercased()
            guard isGitHubSSHHost(host) else { return nil }
            return ownerRepoPair(fromPath: String(trimmed[trimmed.index(after: colon)...]))
        }

        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased() else { return nil }
        if components.scheme?.lowercased() == "ssh" {
            guard isGitHubSSHHost(host) else { return nil }
        } else {
            guard host == "github.com" else { return nil }
        }
        return ownerRepoPair(fromPath: components.path)
    }

    private static func isGitHubSSHHost(_ host: String) -> Bool {
        host == "github.com" || host.hasPrefix("github-")
    }

    private static func ownerRepoPair(fromPath path: String) -> (owner: String, repo: String)? {
        let parts = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count == 2 else { return nil }

        let repo = parts[1].lowercased().hasSuffix(".git")
            ? String(parts[1].dropLast(4))
            : parts[1]
        guard !parts[0].isEmpty, !repo.isEmpty else { return nil }
        return (parts[0], repo)
    }
}
