import SwiftUI
import AppKit

extension AppModel {
    func loadRepos(for account: Account, silent: Bool = false, userInitiated: Bool = true) async {
        let owner = account.alias
        guard !repoLoadsInFlight.contains(owner) else { return }
        repoLoadsInFlight.insert(owner)
        defer { repoLoadsInFlight.remove(owner) }
        if userInitiated { repoAutoRefreshAccounts.insert(owner) }

        let isVisibleAccount = selectedAccount?.alias == owner
        let hasVisibleRepos = isVisibleAccount && !repos.isEmpty
        if isVisibleAccount {
            isLoadingRepos = !hasVisibleRepos
            isRefreshingRepos = hasVisibleRepos
            setRepoRefreshMessage("Refreshing repos…")
            if !silent && !hasVisibleRepos {
                repoSearch = ""
                selectedRepo = nil
                repoStatuses = [:]
            }
        }

        appendLog((silent || hasVisibleRepos) ? "Refreshing repos for \(owner)…" : "Listing repos for \(owner)…")
        let result = await ghSerializedPreservingActiveAccount { GitHub.listRepos(owner: owner) }
        repoLastRefreshAt[owner] = Date()
        if selectedAccount?.alias == owner {
            isLoadingRepos = false
            isRefreshingRepos = false
        }

        switch result {
        case .success(let list):
            repoCache[owner] = list
            appendLog("Found \(list.count) repo(s) for \(owner).")
            if selectedAccount?.alias == owner {
                repos = list
                isCheckingRepoRemotes = true
                setRepoRefreshMessage(nil)
                if let selectedRepo, !list.contains(where: { $0.id == selectedRepo }) {
                    self.selectedRepo = nil
                    selectedRepoCache.removeValue(forKey: owner)
                }
            }
            await refreshClonedStatus(for: account)
            await refreshStatuses(for: account, refreshRemote: true)
            if selectedAccount?.alias == owner {
                isCheckingRepoRemotes = false
                setRepoRefreshMessage("Repos and remote status refreshed just now.", autoDismiss: true)
            }
        case .failure(let error):
            appendLog("✗ repo list failed: \(error.message)")
            if repoCache[owner]?.isEmpty == false {
                appendLog("Showing cached repos for \(owner).")
            }
            if selectedAccount?.alias == owner {
                isCheckingRepoRemotes = false
                setRepoRefreshMessage("Repo refresh failed — showing cached repos.")
            }
        }
    }

    /// Re-scan cloned-repo status on a fixed interval so the row badges pick up
    /// changes made outside the app (editor/terminal). Paused while the app is in
    /// the background; each tick waits for the previous scan to finish.
    func startStatusAutoRefresh() {
        guard statusTimer == nil, appIsActive else { return }
        statusTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.statusRefreshSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self, self.appIsActive else { return }
                await self.autoRefreshStatusesTick()
            }
        }
    }

    func stopStatusAutoRefresh() {
        statusTimer?.cancel()
        statusTimer = nil
    }

    func configureRepoAutoRefresh(seconds: Int) {
        if seconds > 0,
           repoAutoRefreshTimer != nil,
           repoAutoRefreshSeconds == UInt64(seconds) {
            return
        }
        if seconds <= 0,
           repoAutoRefreshTimer == nil,
           repoAutoRefreshSeconds == 0 {
            return
        }

        repoAutoRefreshTimer?.cancel()
        repoAutoRefreshTimer = nil
        guard seconds > 0, appIsActive else {
            repoAutoRefreshSeconds = appIsActive ? 0 : UInt64(seconds)
            if seconds <= 0 {
                isRefreshingRepos = false
                setRepoRefreshMessage(nil)
            }
            return
        }

        repoAutoRefreshSeconds = UInt64(seconds)
        let interval = repoAutoRefreshSeconds
        repoAutoRefreshTimer = Task { [weak self] in
            while !Task.isCancelled {
                // Sleep first, using the captured interval, so `self` isn't held
                // across the wait — matches startStatusAutoRefresh's pattern.
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard !Task.isCancelled, let self, self.appIsActive else { return }
                await self.autoRefreshRepoListTick()
            }
        }
    }

    func stopRepoAutoRefresh() {
        repoAutoRefreshTimer?.cancel()
        repoAutoRefreshTimer = nil
        isRefreshingRepos = false
    }

    /// Single entry point for the repo-refresh status line. With `autoDismiss` the
    /// message clears itself after `refreshMessageLingerSeconds` (used for the
    /// success confirmation so it doesn't linger). Any pending dismissal is
    /// cancelled first, and the delayed clear only fires if the message is still
    /// the one it was scheduled for — so a newer message is never wiped early.
    func setRepoRefreshMessage(_ message: String?, autoDismiss: Bool = false) {
        repoRefreshMessageDismiss?.cancel()
        repoRefreshMessageDismiss = nil
        repoRefreshMessage = message
        guard autoDismiss, let message else { return }
        repoRefreshMessageDismiss = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.refreshMessageLingerSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.repoRefreshMessage == message else { return }
            self.repoRefreshMessage = nil
            self.repoRefreshMessageDismiss = nil
        }
    }

    /// One interval tick: refresh every account you've loaded at least once whose
    /// effective interval has elapsed — not just the visible one — so each stays
    /// current in the background and is already fresh when you switch to it.
    /// Non-visible accounts update only their cache (no UI churn); the visible one
    /// shows the usual indicator. Accounts are refreshed one at a time through the
    /// gh chain, with the selected account last so the visible rows get the freshest
    /// result. Per-owner in-flight guards in loadRepos keep this from stacking on a
    /// manual load already running.
    func autoRefreshRepoListTick() async {
        guard repoAutoRefreshSeconds > 0, !isInitializingProject, !isForkingProject, !addAccountActive else { return }
        let selected = selectedAccount?.alias
        let targets = accounts
            .filter { repoAutoRefreshAccounts.contains($0.alias) }
            .filter { shouldAutoRefreshRepos(for: $0.alias) }
            .sorted { ($0.alias == selected ? 1 : 0) < ($1.alias == selected ? 1 : 0) }
        for account in targets {
            await loadRepos(for: account, silent: true, userInitiated: false)
        }
    }

    /// Whether `alias` is due for an auto-refresh, based on its *effective*
    /// interval. Used by both the timer tick and the on-switch refresh.
    func shouldAutoRefreshRepos(for alias: String) -> Bool {
        let interval = effectiveRefreshInterval(for: alias)
        guard interval > 0 else { return false }
        guard let last = repoLastRefreshAt[alias] else { return true }
        return Date().timeIntervalSince(last) >= TimeInterval(interval)
    }

    /// Per-account refresh interval in seconds (0 when auto-refresh is off). Starts
    /// from the chosen interval, then:
    ///  • accounts you're not viewing are floored to backgroundRefreshFloorSeconds
    ///    (they're refreshed on switch anyway), and
    ///  • large repo lists are stretched ~1× per 500 repos, so the request rate per
    ///    account stays roughly flat no matter how big the list grows.
    /// Net effect: small visible accounts honor your exact interval; many accounts
    /// and/or huge lists back off automatically to stay light on the GitHub API.
    func effectiveRefreshInterval(for alias: String) -> UInt64 {
        guard repoAutoRefreshSeconds > 0 else { return 0 }
        let isVisible = alias == selectedAccount?.alias
        let base = isVisible
            ? repoAutoRefreshSeconds
            : max(repoAutoRefreshSeconds, Self.backgroundRefreshFloorSeconds)
        let count = repoCache[alias]?.count ?? 0
        let sizeMultiplier = UInt64(max(1, (count + 499) / 500))   // ceil(count / 500)
        return base * sizeMultiplier
    }

    /// One interval tick — skip while a load/init is in flight or nothing is loaded.
    func autoRefreshStatusesTick() async {
        guard let account = selectedAccount,
              !isLoadingRepos, !isInitializingProject, !repos.isEmpty,
              // A post-load remote refresh is in flight; let it finish so this
              // local-only tick can't race it and clobber the just-fetched state.
              !isCheckingRepoRemotes else { return }
        await refreshStatuses(for: account)
    }

    /// Probe every cloned repo so rows can show pending work. The regular timer
    /// uses local status only; repo-list loads pass `refreshRemote` to fetch each
    /// upstream once and compare against current GitHub state.
    func refreshStatuses(for account: Account, refreshRemote: Bool = false) async {
        let alias = account.alias
        let sourceRepos = selectedAccount?.alias == alias ? repos : (repoCache[alias] ?? [])
        let sourceCloned = selectedAccount?.alias == alias ? clonedRepos : (clonedReposCache[alias] ?? [])
        let targets = sourceRepos
            .filter { sourceCloned.contains($0.id) }
            .map { (id: $0.id, path: localPath($0, in: account)) }
        guard !targets.isEmpty else {
            repoStatusesCache[alias] = [:]
            if selectedAccount?.alias == alias, !repoStatuses.isEmpty { repoStatuses = [:] }
            return
        }
        let previous = selectedAccount?.alias == alias ? repoStatuses : (repoStatusesCache[alias] ?? [:])
        let next = await run { () -> [Repo.ID: RepoStatus] in
            var out: [Repo.ID: RepoStatus] = [:]
            for target in targets {
                guard var status = GitHub.status(at: target.path, refreshRemote: refreshRemote) else { continue }
                // Local-only rescans don't fetch, so they can't re-confirm the
                // remote — they'd reset every row to `.unchecked` and wipe the
                // green "current after live fetch" pill on the next 10s tick.
                // Carry forward the last live-fetch verdict while the upstream is
                // unchanged (and the fresh parse hasn't found something newer,
                // e.g. `[gone]`).
                if !refreshRemote, status.remoteState == .unchecked, status.hasUpstream,
                   let prev = previous[target.id], prev.remoteState == .checked,
                   prev.upstreamRemote == status.upstreamRemote {
                    status.remoteState = .checked
                }
                out[target.id] = status
            }
            return out
        }
        // Only publish when something actually changed — otherwise the 10s timer
        // would re-render the repo list (and reset hover/tooltip tracking) for nothing.
        repoStatusesCache[alias] = next
        if selectedAccount?.alias == alias, next != repoStatuses { repoStatuses = next }
    }

    // MARK: Per-repo state

    func localPath(_ repo: Repo, in account: Account) -> String {
        (account.folder as NSString).appendingPathComponent(repo.name)
    }

    func isCloned(_ repo: Repo) -> Bool { clonedRepos.contains(repo.id) }

    func isRepoActionBusy(_ repo: Repo) -> Bool {
        guard let account = selectedAccount else {
            return busyRepos.contains(repo.id)
        }
        return busyRepos.contains(repo.id) || busyRepoPaths.contains(localPath(repo, in: account))
    }

    func folderConflict(_ repo: Repo) -> RepoFolderConflict? {
        repoFolderConflicts[repo.id]
    }

    /// Both per-account connection checks (SSH key greeting + gh auth) have passed.
    /// Used to gate the repo/init actions until the account is confirmed reachable.
    func accountReady(_ account: Account) -> Bool {
        accountSSHReady(account) && accountGhReady(account)
    }

    /// True while either connection check for `account` is still in flight (no
    /// result back yet) — distinguishes "still checking" from "checked and failed".
    func accountChecking(_ account: Account) -> Bool {
        accountStatusChecksPending.contains(account.alias)
    }

    func accountStatusKnown(_ account: Account) -> Bool {
        sshGreetings[account.alias] != nil && ghIndicators[account.alias] != nil
    }

    func accountSSHReady(_ account: Account) -> Bool {
        guard let greeting = sshGreetings[account.alias],
              let login = AccountSetup.sshLogin(from: greeting) else { return false }
        return AccountSetup.loginMatches(login, expectedAlias: account.alias)
    }

    func accountGhReady(_ account: Account) -> Bool {
        ghIndicators[account.alias]?.ok == true
    }

    func refreshClonedStatus(for account: Account) async {
        let alias = account.alias
        let sourceRepos = selectedAccount?.alias == alias ? repos : (repoCache[alias] ?? [])
        let scan = await run { () -> (present: Set<Repo.ID>, conflicts: [Repo.ID: RepoFolderConflict]) in
            var present: Set<Repo.ID> = []
            var conflicts: [Repo.ID: RepoFolderConflict] = [:]
            for repo in sourceRepos {
                let path = (account.folder as NSString).appendingPathComponent(repo.name)
                switch Self.localFolderState(for: repo, path: path) {
                case .cloned:
                    present.insert(repo.id)
                case .occupied(let conflict):
                    conflicts[repo.id] = conflict
                case .absent:
                    break
                }
            }
            return (present, conflicts)
        }
        clonedReposCache[alias] = scan.present
        repoFolderConflictsCache[alias] = scan.conflicts
        if selectedAccount?.alias == alias {
            clonedRepos = scan.present
            repoFolderConflicts = scan.conflicts
        }
    }

    /// Persist a cloned/conflict update to `alias`'s cache, mirroring it into the
    /// visible sets only while that account is still the selected one.
    func commitCloneState(_ cloned: Set<Repo.ID>,
                                  _ conflicts: [Repo.ID: RepoFolderConflict],
                                  for alias: String) {
        clonedReposCache[alias] = cloned
        repoFolderConflictsCache[alias] = conflicts
        if selectedAccount?.alias == alias {
            clonedRepos = cloned
            repoFolderConflicts = conflicts
        }
    }

    func makeInitPlan(sourceURL: URL, account: Account) async -> ProjectInitPlan {
        let sourcePath = sourceURL.standardizedFileURL.path
        let accountFolder = URL(fileURLWithPath: account.folder).standardizedFileURL.path
        let repoName = sanitizedRepoName(from: (sourcePath as NSString).lastPathComponent)
        let blockingReason = sourcePath == accountFolder
            ? "Choose an individual project folder, not the account root folder."
            : nil
        let inAccountFolder = sourcePath == accountFolder || sourcePath.hasPrefix(accountFolder + "/")
        let workingPath = inAccountFolder
            ? sourcePath
            : (accountFolder as NSString).appendingPathComponent(repoName)

        // The in-place path refuses on an origin mismatch; the copy path keeps the
        // folder's `.git` and re-points origin, so flag when copying would push a
        // *different* repo's full history. (Local read; doesn't hit the network.)
        var sourceOrigin: String?
        if !inAccountFolder,
           let origin = await run({ GitHub.originURL(at: sourcePath) }),
           !GitHub.remoteLooksLike(origin, owner: account.alias, repoName: repoName) {
            sourceOrigin = origin
        }

        return ProjectInitPlan(
            account: account,
            sourcePath: sourcePath,
            workingPath: workingPath,
            repoName: repoName,
            willCopy: !inAccountFolder,
            blockingReason: blockingReason,
            sourceOrigin: sourceOrigin
        )
    }

}
