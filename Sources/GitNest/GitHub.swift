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
    /// Pre-lowercased fields used by the search matcher so the search loop doesn't
    /// reallocate lowercased strings on every keystroke.
    let searchableHaystacks: [String]

    init(name: String, nameWithOwner: String, description: String?, visibility: String, updatedAt: String?, url: String) {
        self.name = name
        self.nameWithOwner = nameWithOwner
        self.description = description
        self.visibility = visibility
        self.updatedAt = updatedAt
        self.url = url
        self.searchableHaystacks = [name, nameWithOwner, description ?? ""].map { $0.lowercased() }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        nameWithOwner = try container.decode(String.self, forKey: .nameWithOwner)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        visibility = try container.decode(String.self, forKey: .visibility)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        url = try container.decode(String.self, forKey: .url)
        searchableHaystacks = [name, nameWithOwner, description ?? ""].map { $0.lowercased() }
    }

    private enum CodingKeys: String, CodingKey {
        case name, nameWithOwner, description, visibility, updatedAt, url
    }

    /// Owner login parsed from `nameWithOwner` (the part before the slash).
    var owner: String { String(nameWithOwner.prefix { $0 != "/" }) }
}

/// A repo as returned by the REST `user/repos` endpoint. Mapped into `Repo`.
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
    // `gh repo view --json parent` exposes the parent as `{name, owner: {login}}`
    // — it does NOT include a flat `nameWithOwner` like the top-level repo does.
    // Decode the nested shape and compose the name ourselves.
    struct Parent: Decodable {
        struct Owner: Decodable {
            let login: String
        }
        let name: String
        let owner: Owner

        var nameWithOwner: String { "\(owner.login)/\(name)" }
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

/// Error carrying a human-readable message from a failed shell command or parser.
struct CommandError: Error, Sendable {
    let message: String
}

/// Result of a fork request. `alreadyExisted` is true when the user already had
/// the fork (`gh repo fork` is idempotent and just reports it), so callers can
/// say "cloning your existing fork" instead of implying a fresh one was created.
struct ForkOutcome: Sendable {
    let repo: Repo
    let alreadyExisted: Bool
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

    /// GitHub account and organization names use the same rules as user logins.
    private static func isValidOwner(_ name: String) -> Bool {
        isValidGitHubLogin(name)
    }

    /// Repository names can contain dots, underscores, and repeated hyphens.
    /// The app still rejects path separators and empty/special names before calling git.
    private static func isValidRepo(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100 else { return false }
        guard name != ".", name != "..", name.lowercased() != ".git" else { return false }
        guard !name.hasPrefix("."), !name.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
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
    var stashCount: Int = 0     // entries on the stash stack (parked locally, not on GitHub)
    var ahead: Int = 0          // local commits not yet pushed
    var behind: Int = 0         // remote commits not yet pulled
    var hasUpstream: Bool = false
    /// Full upstream ref from porcelain (e.g. `origin/main`). Used to detect when
    /// tracking changes so a live-fetch `.checked` verdict is not carried forward
    /// across a different upstream branch on the same remote.
    var upstreamRef: String?
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
                let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                status.hasUpstream = rest.contains("...")
                // Tracking info "[ahead N, behind M]" or "[gone]" appears only after
                // the upstream name. Parse the trailing bracket region only after the
                // "..." marker so brackets inside branch names are not misread.
                // `upstreamRemote` is set from the parsed upstream ref below; with no
                // "..." there is no upstream, so it stays nil.
                if let marker = rest.range(of: "...") {
                    let afterUpstream = String(rest[marker.upperBound...])
                    // The upstream reference may contain spaces or slashes (e.g.
                    // "origin/my branch"). Split it from the trailing "[...]"
                    // tracking info first, then extract the remote from the part
                    // before the first '/'.
                    let (upstreamRef, tracking) = splitUpstreamAndTracking(afterUpstream)
                    status.upstreamRef = upstreamRef.isEmpty ? nil : upstreamRef
                    status.upstreamRemote = upstreamRemote(from: upstreamRef)
                    if tracking.hasPrefix("["), tracking.hasSuffix("]") {
                        let inner = tracking.dropFirst().dropLast()
                        for part in inner.split(separator: ",") {
                            let token = part.trimmingCharacters(in: .whitespaces)
                            if token.hasPrefix("ahead "), let n = Int(token.dropFirst(6)) { status.ahead = n }
                            if token.hasPrefix("behind "), let n = Int(token.dropFirst(7)) { status.behind = n }
                            // "[gone]" — upstream configured but deleted on the remote.
                            // Without this, a gone branch would read as clean/current.
                            if token == "gone" { status.remoteState = .upstreamGone }
                        }
                    }
                }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                status.changedFiles += 1
            }
        }
        return status
    }

    /// Split the upstream reference from the trailing "[...]" tracking block.
    /// The upstream reference itself may contain spaces; tracking is only
    /// recognized when it is a bracketed suffix preceded by whitespace.
    private static func splitUpstreamAndTracking(_ text: String) -> (upstream: String, tracking: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.lastIndex(of: "["),
              open > trimmed.startIndex,
              let before = trimmed.index(open, offsetBy: -1, limitedBy: trimmed.startIndex),
              (trimmed[before] == " " || trimmed[before] == "\t"),
              let close = trimmed.lastIndex(of: "]"),
              close > open,
              close == trimmed.index(before: trimmed.endIndex) else {
            return (trimmed, "")
        }
        let upstream = String(trimmed[..<before]).trimmingCharacters(in: .whitespaces)
        let tracking = String(trimmed[open...])
        return (upstream, tracking)
    }

    private static func upstreamRemote(from upstream: String) -> String? {
        guard let slash = upstream.firstIndex(of: "/") else { return nil }
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
    /// Non-nil when the selected source is unsafe or invalid for project init.
    /// The UI shows this and disables creation; the backend also refuses it so a
    /// stale sheet cannot initialize the wrong folder.
    var blockingReason: String? = nil
    /// When the source folder is itself a clone of a *different* repo, its origin
    /// URL. The copy path drops that repo's `.git` so its history is NOT republished
    /// to the new repo; this is surfaced in the confirmation so the user knows the
    /// new project starts fresh. nil when it's not a clone (or already points at the
    /// target repo).
    var sourceOrigin: String? = nil
    /// Non-blocking warning shown when the repo name had to be sanitized away from
    /// the source folder's name (e.g. an all-punctuation folder collapses to
    /// "new-repo"). nil when the sanitized name is recognizably derived from the
    /// source. Lets the user catch a surprising push target before confirming,
    /// without blocking creation the way `blockingReason` does.
    var repoNameWarning: String? = nil

    var sourceName: String {
        (sourcePath as NSString).lastPathComponent
    }

    static func pathBlockingReason(sourcePath: String, accountFolder: String) -> String? {
        let source = normalizedPath(sourcePath)
        let accountRoot = normalizedPath(accountFolder)
        if source == accountRoot {
            return "Choose an individual project folder, not the account root folder."
        }
        if path(accountRoot, isInside: source) {
            return "Choose an individual project folder, not a parent folder that contains the account root folder."
        }
        return nil
    }

    static func copyBlockingReason(sourcePath: String, workingPath: String, willCopy: Bool) -> String? {
        guard willCopy else { return nil }
        let source = normalizedPath(sourcePath)
        let destination = normalizedPath(workingPath)
        guard path(destination, isInside: source) else { return nil }
        return "The copy destination is inside the selected source folder. Choose a more specific project folder."
    }

    private static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        // Resolve symlinks so a source folder that is a symlink to the account
        // root (or vice versa) is recognized for what it is.
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        return resolved.standardizedFileURL.path
    }

    private static func path(_ child: String, isInside parent: String) -> Bool {
        guard child != parent else { return false }
        if parent == "/" { return child.hasPrefix("/") }
        return child.hasPrefix(parent + "/")
    }

    /// A warning when the sanitized repo name diverges enough from the source
    /// folder name that the push target would surprise the user — e.g. a folder
    /// named "...---..." collapses to "new-repo", or a Unicode name gets flattened
    /// to hyphens. Returns nil when the sanitized name is recognizably derived
    /// from the source. Non-blocking: the sheet surfaces it so the user can rename
    /// the folder and retry, but does not disable "Init & push" the way
    /// `blockingReason` does.
    static func repoNameWarning(sourceName: String, sanitizedRepoName: String) -> String? {
        guard !sanitizedRepoName.isEmpty else { return nil }
        if sourceName.lowercased() == sanitizedRepoName.lowercased() { return nil }
        // Recognizably derived: the sanitized name's *alphanumeric* characters
        // (ignoring the hyphens/periods sanitization inserts to replace punctuation)
        // appear, in order, among the source's alphanumeric characters. "my cool
        // app" → "my-cool-app" shares [m,y,c,o,o,l,a,p,p] and stays quiet; "...---..."
        // → "new-repo" shares nothing and warns.
        let srcAlnum = String(sourceName.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        let dstAlnum = String(sanitizedRepoName.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        // Reuses the search bar's subsequence matcher. The `!dstAlnum.isEmpty` guard
        // keeps the empty case explicit (an all-punctuation name shares nothing and
        // should warn), independent of how the matcher treats an empty needle.
        if !dstAlnum.isEmpty, WildcardMatcher.isSubsequence(dstAlnum, of: srcAlnum) { return nil }
        return """
        The folder name “\(sourceName)” isn’t a valid GitHub repo name and was sanitized to “\(sanitizedRepoName)”. \
        Rename the folder (alphanumerics, dots, underscores, and hyphens only) if you want a different repo name.
        """
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
    /// Args for `gh auth status`. Deliberately omits `--show-token`: this output is
    /// appended to the Output log, and `gh` masks the token only when not asked to
    /// show it. Kept as a seam so a test can pin the no-`--show-token` invariant
    /// (the redaction sink in `LogStore` is the backstop, this is the front line).
    static func authStatusArgs() -> [String] { ["gh", "auth", "status"] }

    /// Raw `gh auth status` text — shown so you can see which accounts are logged in.
    static func authStatus() -> ShellResult {
        Shell.run(authStatusArgs())
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
    /// `handle` lets the caller kill the long-lived login poll on cancel.
    static func authLoginWebWithClipboard(handle: Shell.ProcessHandle? = nil) -> ShellResult {
        Shell.run([
            "gh", "auth", "login",
            "--hostname", "github.com",
            "--web",
            "--clipboard",
            "--git-protocol", "ssh",
            "--skip-ssh-key"
        ], handle: handle)
    }

    /// Best-effort: make `owner` the active gh account so its private repos are visible.
    @discardableResult
    static func switchTo(_ owner: String) -> ShellResult {
        Shell.run(["gh", "auth", "switch", "-u", owner])
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

    /// Shared rate-limit backoff state. Writes happen only inside the serialized
    /// `ghChain`, but the lock keeps the check itself thread-safe for tests and
    /// any future non-serialized readers.
    private static let rateLimitLock = NSLock()
    private static var rateLimitBackoffUntilByOwner: [String: Date] = [:]

    /// Seconds to wait after hitting a rate limit before allowing auto-refresh
    /// to try again. GitHub's REST rate-limit window is one hour; five minutes
    /// is conservative enough to avoid thrashing without going silent for long.
    static let rateLimitBackoffSeconds: TimeInterval = 300

    /// True while the app is within the backoff window following a rate-limit
    /// response from a `gh api` call. Production callers pass an owner so one
    /// account's REST budget does not suppress every other account.
    static func isRateLimited(owner: String? = nil) -> Bool {
        rateLimitLock.lock()
        defer { rateLimitLock.unlock() }

        let now = Date()
        let expired = rateLimitBackoffUntilByOwner
            .filter { now >= $0.value }
            .map(\.key)
        for key in expired {
            rateLimitBackoffUntilByOwner.removeValue(forKey: key)
        }

        guard let owner else {
            return !rateLimitBackoffUntilByOwner.isEmpty
        }
        return rateLimitBackoffUntilByOwner[rateLimitKey(for: owner)] != nil
    }

    static func recordRateLimitBackoff(owner: String? = nil, seconds: TimeInterval = rateLimitBackoffSeconds) {
        rateLimitLock.lock()
        rateLimitBackoffUntilByOwner[rateLimitKey(for: owner)] = Date().addingTimeInterval(seconds)
        rateLimitLock.unlock()
    }

    /// Clears active backoff. Test-only seam — production callers rely on the
    /// window expiring naturally.
    static func clearRateLimitBackoff(owner: String? = nil) {
        rateLimitLock.lock()
        if let owner {
            rateLimitBackoffUntilByOwner.removeValue(forKey: rateLimitKey(for: owner))
        } else {
            rateLimitBackoffUntilByOwner = [:]
        }
        rateLimitLock.unlock()
    }

    private static func rateLimitKey(for owner: String?) -> String {
        guard let owner, !owner.isEmpty else {
            return "__global__"
        }
        return owner.lowercased()
    }

    private static func isRateLimitError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("rate limit") || lower.contains("api rate limit")
    }

    private static func recordRateLimitIfNeeded(_ res: ShellResult, owner: String) {
        let msg = res.stderr.isEmpty ? res.stdout : res.stderr
        if isRateLimitError(msg) {
            recordRateLimitBackoff(owner: owner)
        }
    }

    /// List every repo `owner` can see: the repos it owns, plus repos it has been
    /// added to as a collaborator (owned by someone else). Switches to that
    /// account first so private repos are visible.
    static func listRepos(owner: String) -> Result<[Repo], CommandError> {
        listRepos(owner: owner,
                  ensureActive: ensureActiveAccount,
                  ownedRepos: { ownedRepos(owner: owner) },
                  collaboratorRepos: { collaboratorRepos(owner: owner) },
                  organizationMemberRepos: { organizationMemberRepos(owner: owner) })
    }

    static func listRepos(owner: String,
                          ensureActive: (String) -> ShellResult,
                          ownedRepos: () -> Result<[Repo], CommandError>,
                          collaboratorRepos: () -> [Repo],
                          organizationMemberRepos: () -> [Repo]) -> Result<[Repo], CommandError> {
        let accountCheck = ensureActive(owner)
        guard accountCheck.ok else {
            let detail = (accountCheck.stderr.isEmpty ? accountCheck.stdout : accountCheck.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CommandError(message: detail.isEmpty
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

        // Best-effort: fold in collaborator and organization-member repos. A
        // failure here must not break the owned list, so errors are ignored.
        var byID: [String: Repo] = [:]
        for repo in owned { byID[repo.id] = repo }
        for repo in collaboratorRepos() where byID[repo.id] == nil { byID[repo.id] = repo }
        for repo in organizationMemberRepos() where byID[repo.id] == nil { byID[repo.id] = repo }

        let merged = byID.values.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        return .success(merged)
    }

    /// Repos owned by the active account. Uses the REST endpoint instead of
    /// `gh repo list --limit ...` so it can paginate without a silent cap.
    private static func ownedRepos(owner: String) -> Result<[Repo], CommandError> {
        let res = Shell.run([
            "gh", "api", "user/repos?affiliation=owner&per_page=100",
            "--paginate", "--slurp",
        ])
        guard res.ok else {
            recordRateLimitIfNeeded(res, owner: owner)
            let msg = res.stderr.isEmpty ? res.stdout : res.stderr
            return .failure(CommandError(message: msg.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard let repos = decodeSlurpedRestRepos(res.stdout) else {
            return .failure(CommandError(message: "could not parse gh repo output"))
        }
        return .success(repos)
    }

    /// Repos the active account collaborates on but does not own. `affiliation=
    /// collaborator` excludes owned and org-member repos, so there is no overlap
    /// with the owned REST list. Best-effort: returns [] on any error.
    private static func collaboratorRepos(owner: String) -> [Repo] {
        let res = Shell.run([
            "gh", "api", "user/repos?affiliation=collaborator&per_page=100",
            "--paginate", "--slurp",
        ])
        if !res.ok { recordRateLimitIfNeeded(res, owner: owner) }
        guard res.ok, let repos = decodeSlurpedRestRepos(res.stdout) else { return [] }
        return repos
    }

    /// Repos the active account has access to through organization membership.
    /// Best-effort: returns [] on any error.
    private static func organizationMemberRepos(owner: String) -> [Repo] {
        let res = Shell.run([
            "gh", "api", "user/repos?affiliation=organization_member&per_page=100",
            "--paginate", "--slurp",
        ])
        if !res.ok { recordRateLimitIfNeeded(res, owner: owner) }
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

    /// Clone into the account's folder using the per-account SSH alias
    /// (`git@github-<alias>:owner/repo.git`). The dedicated SSH config host
    /// selects the right key, and the `url.<alias>.insteadOf` rule also makes
    /// this URL rewrite back to `github.com` for git's own networking.
    static func clone(repo: Repo, sshHost: String, into folder: String) -> ShellResult {
        let url = "git@\(sshHost):\(repo.nameWithOwner).git"
        let dest = (folder as NSString).appendingPathComponent(repo.name)
        if FileManager.default.fileExists(atPath: dest) {
            return ShellResult(exitCode: 1, stdout: "", stderr: "already exists: \(dest)")
        }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        } catch {
            return ShellResult(exitCode: 1, stdout: "", stderr: "could not create folder: \(error.localizedDescription)")
        }
        return Shell.run(["git", "clone", url, dest])
    }

    /// Capability cache: does this `gh` CLI understand `--default-branch-only`
    /// for `gh repo fork`? Detected lazily from `gh repo fork --help`.
    private static var defaultBranchOnlyForkSupported: Bool?

    static func supportsDefaultBranchOnlyFork() -> Bool {
        if let cached = defaultBranchOnlyForkSupported { return cached }
        let help = Shell.run(["gh", "repo", "fork", "--help"])
        let supported = help.ok && (help.stdout + help.stderr).contains("--default-branch-only")
        defaultBranchOnlyForkSupported = supported
        return supported
    }

    /// Fork `source` into the active user's account and return the resulting repo.
    /// Does not clone; callers should clone separately using the returned `Repo`.
    /// Waits up to `timeoutSeconds` for the fork to become available via the API.
    /// The `defaultBranchOnly` flag is silently ignored on older `gh` CLIs that
    /// don't support it, so the fork still succeeds rather than failing with an
    /// unknown-flag error.
    ///
    /// The whole call (switch + fork + poll) runs inside the caller's
    /// `ghChain.serializedPreservingActiveAccount` hop. The poll must stay there
    /// too: `gh repo view` of a *private* fork requires the forking account to be
    /// active, and `serializedPreservingActiveAccount` only restores the original
    /// account once this returns — so splitting the poll off the chain would read
    /// as the wrong user and time out on private forks. Holding the chain for the
    /// poll is the intended trade-off; the exponential backoff in `waitForRepo`
    /// keeps the hold short in practice (most forks land in seconds).
    static func fork(source: RepoReference,
                     intoAccount alias: String,
                     defaultBranchOnly: Bool = true,
                     timeoutSeconds: UInt64 = 60) -> Result<ForkOutcome, CommandError> {
        let accountCheck = ensureActiveAccount(alias)
        guard accountCheck.ok else {
            let detail = (accountCheck.stdout + accountCheck.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CommandError(message: detail.isEmpty ? "Could not switch to account \(alias)" : detail))
        }

        guard let currentUser = currentLogin() else {
            return .failure(CommandError(message: "Could not determine the active GitHub user."))
        }

        var forkArgs = ["gh", "repo", "fork", source.nameWithOwner, "--clone=false"]
        if defaultBranchOnly, supportsDefaultBranchOnlyFork() {
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
                return .success(ForkOutcome(repo: existing, alreadyExisted: true))
            }

            let msg = (forkRes.stderr + forkRes.stdout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CommandError(message: msg.isEmpty ? "fork failed" : msg))
        }

        // `gh repo fork` succeeds (exit 0) whether it created the fork or found one
        // you already had — in the latter case it prints "<owner/repo> already
        // exists". Detect that so the caller can phrase the log honestly.
        let alreadyExisted = forkOutput.range(of: "already exists", options: .caseInsensitive) != nil

        let forkedNameWithOwner = forkedRepoNameWithOwner(
            from: forkOutput,
            currentUser: currentUser,
            fallbackRepo: source.repo
        )
        return waitForRepo(nameWithOwner: forkedNameWithOwner,
                           timeoutSeconds: timeoutSeconds)
            .map { ForkOutcome(repo: $0, alreadyExisted: alreadyExisted) }
    }

    static func forkedRepoNameWithOwner(from output: String,
                                        currentUser: String,
                                        fallbackRepo: String) -> String {
        forkedRepoNameCandidates(from: output, currentUser: currentUser, fallbackRepo: fallbackRepo).first ?? "\(currentUser)/\(fallbackRepo)"
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
                                    timeoutSeconds: UInt64) -> Result<Repo, CommandError> {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var delay: TimeInterval = 1.0
        let maxDelay: TimeInterval = 8.0

        while Date() < deadline {
            if let repo = repoView(nameWithOwner: nameWithOwner) {
                return .success(repo)
            }
            // Not ready yet; back off exponentially (1s, 2s, 4s… capped). Most forks
            // land in seconds, so this avoids ~60 sequential `gh repo view` calls in
            // the serialized chain. Never sleep past the deadline.
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(delay, remaining))
            delay = min(delay * 2, maxDelay)
        }

        return .failure(CommandError(message: """
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
        guard view.ok else { return nil }
        return decodeRepoViewDetails(fromJSON: view.stdout)
    }

    /// Decode one `gh repo view --json …,parent` payload into `RepoViewDetails`.
    /// Exposed (not `private`) so tests can cover the fork-detection decode — the
    /// path that previously broke because `gh`'s nested `parent` shape doesn't
    /// match a flat `nameWithOwner` — without hitting the network.
    static func decodeRepoViewDetails(fromJSON json: String) -> RepoViewDetails? {
        guard let data = json.data(using: .utf8),
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

    /// Download new commits/tags for the current branch's remote (default
    /// `origin`) and prune deleted remote-tracking refs. Unlike `pull`, it never
    /// touches the working tree or current branch, so it's safe with uncommitted
    /// changes. Not `--quiet`, so the summary of what arrived shows in the Output
    /// pane.
    static func fetch(at path: String) -> ShellResult {
        runFetch(["git", "-C", path, "fetch", "--prune"])
    }

    /// Run a fetch, retrying once if a concurrent fetch on the same repo briefly held
    /// a ref lock ("cannot lock ref" / "unable to update local ref"). A manual Fetch
    /// and the background repo-list refresh can target one repo at the same time;
    /// fetch is idempotent, so a single retry clears that transient clash instead of
    /// surfacing a confusing error.
    private static func runFetch(_ args: [String]) -> ShellResult {
        let res = Shell.run(args)
        guard !res.ok else { return res }
        let text = (res.stdout + res.stderr).lowercased()
        guard text.contains("cannot lock ref") || text.contains("unable to update local ref") else {
            return res
        }
        Thread.sleep(forTimeInterval: 0.4)
        return Shell.run(args)
    }

    /// True when the working tree has any uncommitted or untracked changes.
    /// Network-free; failures are explicit so destructive callers can fail closed.
    static func hasUncommittedChanges(at path: String) -> Result<Bool, CommandError> {
        let res = Shell.run([
            "git", "--no-optional-locks", "-C", path, "status", "--porcelain"
        ])
        guard res.ok else {
            return .failure(CommandError(message: conciseMessage(res, fallback: "git status failed")))
        }
        return .success(!res.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        // Surface parked work the change badge can't: stashing drops changedFiles to
        // 0, so without this a clone with a stash would read as clean. Cheap, local,
        // and never fails a status pass (stashCount returns 0 on any error).
        let stashes = stashCount(at: path)
        status.stashCount = stashes
        guard refreshRemote else { return status }

        guard status.hasUpstream else {
            status.remoteState = .noUpstream
            return status
        }

        let remote = status.upstreamRemote ?? "origin"
        let fetch = runFetch([
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
        next.stashCount = stashes   // unchanged by the fetch between the two parses
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

    static func origin(at path: String, matches repo: Repo, expectedSSHHost: String? = nil) -> Bool {
        guard let existing = originURL(at: path) else { return false }
        return remoteLooksLike(existing,
                               owner: repo.owner,
                               repoName: repo.name,
                               expectedSSHHost: expectedSSHHost)
    }

    static func originURL(at path: String) -> String? {
        let origin = Shell.run(["git", "-C", path, "remote", "get-url", "origin"])
        guard origin.ok else { return nil }
        let existing = origin.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return existing.isEmpty ? nil : existing
    }

    /// Whether a failed `gh repo create` failed *because the name is already taken*
    /// (vs. rate limit, auth, network, name policy). Only a real collision justifies
    /// adopting an existing repo and pushing into it. gh phrases this as e.g.
    /// "GraphQL: Name already exists on this account (createRepository)".
    static func createReportedNameCollision(_ result: ShellResult) -> Bool {
        // gh reports this on stderr, but check stdout too so a future gh that routes
        // it differently can't silently turn this back into "any failure = exists".
        // Match the known collision phrasing and fail closed for anything else.
        let text = (result.stderr + "\n" + result.stdout).lowercased()
        return text.contains("name already exists on this account")
            || text.contains("already exists on this account")
    }

    static func initAndPushProject(_ plan: ProjectInitPlan, visibility: RepoVisibilityChoice) -> ShellResult {
        var log: [String] = []
        let fm = FileManager.default
        let owner = plan.account.alias
        let repoFullName = "\(owner)/\(plan.repoName)"
        let remoteURL = "git@\(plan.account.sshHost):\(repoFullName).git"

        if let reason = plan.blockingReason
            ?? ProjectInitPlan.pathBlockingReason(sourcePath: plan.sourcePath,
                                                  accountFolder: plan.account.folder)
            ?? ProjectInitPlan.copyBlockingReason(sourcePath: plan.sourcePath,
                                                  workingPath: plan.workingPath,
                                                  willCopy: plan.willCopy) {
            return failure(reason, log)
        }

        do {
            try fm.createDirectory(atPath: plan.account.folder, withIntermediateDirectories: true)
            if plan.willCopy {
                if fm.fileExists(atPath: plan.workingPath) {
                    return failure("destination already exists: \(plan.workingPath)", log)
                }
                try fm.copyItem(atPath: plan.sourcePath, toPath: plan.workingPath)
                log.append("Copied project to \(plan.workingPath)")
                let copiedGit = (plan.workingPath as NSString).appendingPathComponent(".git")
                let copiedOrigin = originURL(at: plan.workingPath)
                let shouldDropCopiedGit = copiedOrigin.map {
                    !remoteLooksLike($0,
                                     owner: owner,
                                     repoName: plan.repoName,
                                     expectedSSHHost: plan.account.sshHost)
                } ?? (plan.sourceOrigin != nil)
                if fm.fileExists(atPath: copiedGit), shouldDropCopiedGit {
                    // The source is a clone of a *different* repo. Its copied `.git`
                    // carries that repo's full history and foreign origin; re-homing
                    // and pushing it would republish another (possibly private) repo's
                    // history into this brand-new repo. Drop the copied `.git` so the
                    // new project starts a fresh, single-commit history instead.
                    try? fm.removeItem(atPath: copiedGit)
                    // Gate on the postcondition, not the removal error: a `.git` that
                    // was already absent (stale plan) is fine, but one that survived a
                    // failed removal must NOT fall through — willCopy skips the
                    // origin-mismatch guard below, so we'd republish the foreign repo's
                    // history. Only proceed once the foreign `.git` is provably gone.
                    guard !fm.fileExists(atPath: copiedGit) else {
                        return failure("could not start fresh history: copied .git is still present at \(copiedGit)", log)
                    }
                    log.append("Started fresh history (did not copy the source's existing Git history)")
                }
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
            guard remoteLooksLike(existing,
                                  owner: owner,
                                  repoName: plan.repoName,
                                  expectedSSHHost: plan.account.sshHost) else {
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
        } else if createReportedNameCollision(create), repoView(nameWithOwner: repoFullName) != nil {
            // Only adopt a pre-existing repo when gh actually reported a name
            // collision. Treating *any* create failure as "already exists" would
            // mask real errors (rate limit, network, name policy) and silently
            // push into a coincidentally same-named repo the user already owns.
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

    /// Path to the bundled GitHub `known_hosts` file, if the app was assembled
    /// with one (production builds). Falls back to the user's `~/.ssh/known_hosts`
    /// when running from `swift run`/tests.
    private static var pinnedKnownHostsPath: String? {
        Bundle.main.path(forResource: "known_hosts", ofType: nil)
    }

    /// `ssh -T git@github-<alias>` returns "Hi <name>!" on stderr — the auth check.
    /// BatchMode forbids interactive prompts (there's no terminal to answer on),
    /// ConnectTimeout keeps a dead network from stalling the status sweep, and
    /// StrictHostKeyChecking=yes pins GitHub's host key instead of accepting any
    /// new key silently.
    static func sshGreeting(host: String) -> String {
        var args = [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=yes",
        ]
        if let knownHosts = pinnedKnownHostsPath {
            args += ["-o", "UserKnownHostsFile=\(knownHosts)"]
        }
        args += ["-T", "git@\(host)"]
        let res = Shell.run(args)
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
    static func remoteLooksLike(_ remote: String,
                                owner: String,
                                repoName: String,
                                expectedSSHHost: String? = nil) -> Bool {
        guard let parsed = githubRemoteOwnerRepo(remote) else { return false }
        if let expectedSSHHost,
           let sshHost = parsed.sshHost,
           sshHost != "github.com",
           sshHost.caseInsensitiveCompare(expectedSSHHost) != .orderedSame {
            return false
        }
        return parsed.owner.caseInsensitiveCompare(owner) == .orderedSame
            && parsed.repo.caseInsensitiveCompare(repoName) == .orderedSame
    }

    private static func githubRemoteOwnerRepo(_ remote: String) -> (owner: String, repo: String, sshHost: String?)? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }

        if let at = trimmed.firstIndex(of: "@"),
           let colon = trimmed[at...].firstIndex(of: ":"),
           at < colon {
            let host = String(trimmed[trimmed.index(after: at)..<colon]).lowercased()
            guard isGitHubSSHHost(host) else { return nil }
            guard let pair = ownerRepoPair(fromPath: String(trimmed[trimmed.index(after: colon)...])) else {
                return nil
            }
            return (pair.owner, pair.repo, host)
        }

        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased() else { return nil }
        if components.scheme?.lowercased() == "ssh" {
            guard isGitHubSSHHost(host) else { return nil }
            guard let pair = ownerRepoPair(fromPath: components.path) else { return nil }
            return (pair.owner, pair.repo, host)
        } else {
            guard host == "github.com" else { return nil }
        }
        guard let pair = ownerRepoPair(fromPath: components.path) else { return nil }
        return (pair.owner, pair.repo, nil)
    }

    private static func isGitHubSSHHost(_ host: String) -> Bool {
        if host == "github.com" { return true }
        guard host.hasPrefix("github-") else { return false }
        let alias = host.dropFirst("github-".count)
        guard !alias.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        return alias.unicodeScalars.allSatisfy { allowed.contains($0) }
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
