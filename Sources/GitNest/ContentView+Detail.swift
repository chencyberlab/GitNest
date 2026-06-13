import SwiftUI
import AppKit

extension ContentView {
    // MARK: Detail — repos + actions

    var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let account = model.selectedAccount {
                header(account)
                Divider().overlay(theme.border)
                if !model.isLoadingRepos && !model.repos.isEmpty {
                    repoSearchBar
                }
                repoList(account)
                cloneBar
            } else {
                Spacer()
                Text("Select an account on the left.")
                    .font(.system(size: 14)).foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            Divider().overlay(theme.border)
            outputPane
        }
        .padding(18)
        .background(theme.surface)
    }

    func header(_ account: Account) -> some View {
        let ready = model.accountReady(account)
        let gateHint = connectionGateHint(account)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name).font(Theme.display(22))
                Label(account.folder, systemImage: "folder")
                    .font(.system(size: 11)).foregroundStyle(theme.textMuted)
            }
            Spacer()
            HStack(spacing: 10) {
                Button {
                    chooseInitFolder(for: account)
                } label: {
                    Label("Init project", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
                .tooltip(gateHint ?? "Choose a local project folder, create a GitHub repo, and push it")
                .disabled(!ready || model.isInitializingProject || model.isLoadingRepos || model.isForkingProject)

                Button {
                    showForkSheet = true
                    forkAddress = ""
                } label: {
                    Label("Fork project", systemImage: "tuningfork")
                }
                .buttonStyle(PrimaryButtonStyle())
                .tooltip(gateHint ?? "Fork a GitHub repository into this account and clone it")
                .disabled(!ready || model.isInitializingProject || model.isLoadingRepos || model.isForkingProject)

                Button {
                    Task { await model.loadRepos(for: account) }
                } label: {
                    Label("Load repos", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(PrimaryButtonStyle())
                .tooltip(gateHint ?? "List every repo \(account.alias) owns (via gh)")
                .disabled(!ready || model.isLoadingRepos || model.isInitializingProject || model.isForkingProject)
            }
        }
    }

    /// Why the action buttons are greyed out (nil once the account is ready) —
    /// surfaced as the buttons' tooltip so the disabled state isn't a mystery.
    func connectionGateHint(_ account: Account) -> String? {
        if model.accountReady(account) { return nil }
        if model.accountChecking(account) {
            return "Checking SSH and GitHub connection for \(account.alias)…"
        }
        if !model.accountStatusKnown(account) {
            return "Connection status has not been checked for \(account.alias) yet. Select the card or press Refresh."
        }
        return "SSH or GitHub isn't ready for \(account.alias). Fix it on the account card (SSH / GitHub login), then Refresh."
    }

    func chooseInitFolder(for account: Account) {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.message = "Select the project folder to initialize and push to \(account.alias)."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        initVisibility = .private
        moveOriginalToTrash = false
        Task { initPlan = await model.makeInitPlan(sourceURL: url, account: account) }
    }

    func startProjectInit(_ plan: ProjectInitPlan,
                                  visibility: RepoVisibilityChoice,
                                  moveOriginalToTrash: Bool) {
        initPlan = nil
        Task {
            let ok = await model.initProject(
                plan,
                visibility: visibility,
                moveOriginalToTrash: moveOriginalToTrash
            )
            if ok {
                await model.loadRepos(for: plan.account)
            }
        }
    }

    func initProjectSheet(_ plan: ProjectInitPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Initialize Project")
                    .font(Theme.title(18))
                Text("\(plan.account.alias)/\(plan.repoName)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textMuted)
            }

            Divider().overlay(theme.border)

            VStack(alignment: .leading, spacing: 10) {
                Label(plan.sourcePath, systemImage: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(2)
                    .truncationMode(.middle)

                if let blockingReason = plan.blockingReason {
                    Label(blockingReason, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                } else if plan.willCopy {
                    Label("Will copy to \(plan.workingPath)", systemImage: "arrow.turn.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textMuted)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("Use the copied folder for future development after upload.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                    if let origin = plan.sourceOrigin {
                        Label("This folder is a clone of \(origin) — its full commit history will be pushed to \(plan.account.alias)/\(plan.repoName).",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label("Already inside \(plan.account.alias)'s GitHub folder; will initialize in place.",
                          systemImage: "checkmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.success)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Repo type")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                Picker("Repo type", selection: $initVisibility) {
                    ForEach(RepoVisibilityChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if plan.blockingReason == nil, plan.willCopy {
                Toggle("Move original selected folder to Trash after upload", isOn: $moveOriginalToTrash)
                    .font(.system(size: 12, weight: .medium))
                Text("The copied folder in \(plan.account.alias)'s GitHub folder will remain.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            } else if plan.blockingReason == nil {
                Label("Trash cleanup is unavailable because this folder is already in the account folder.",
                      systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    initPlan = nil
                }
                .buttonStyle(SubtleButtonStyle())

                Button {
                    startProjectInit(
                        plan,
                        visibility: initVisibility,
                        moveOriginalToTrash: plan.willCopy && moveOriginalToTrash
                    )
                } label: {
                    Label("Create Repo", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(plan.blockingReason != nil)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(theme.surface)
    }

    var forkProjectSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Fork Project")
                    .font(Theme.title(18))
                Text("Enter the GitHub repository address to fork into \(model.selectedAccount?.alias ?? "this account").")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(2)
            }

            Divider().overlay(theme.border)

            VStack(alignment: .leading, spacing: 8) {
                Text("GitHub project address")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                TextField("e.g. https://github.com/owner/repo or owner/repo", text: $forkAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(model.isForkingProject)
                Text("The repository will be forked to your account, then cloned into the account folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isForkingProject {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Forking and cloning…")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textMuted)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showForkSheet = false
                }
                .buttonStyle(SubtleButtonStyle())
                .disabled(model.isForkingProject)

                Button {
                    let address = forkAddress
                    let account = model.selectedAccount
                    Task {
                        guard let account else { return }
                        let ok = await model.forkProject(source: address, account: account)
                        if ok {
                            showForkSheet = false
                        }
                        // On failure, keep the sheet open so the user can retry.
                    }
                } label: {
                    Label("Fork & Clone", systemImage: "tuningfork")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.isForkingProject || RepoReference.parse(forkAddress) == nil)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(theme.surface)
    }

    // MARK: Repo list (custom selection, no system blue)

    @ViewBuilder
    func repoList(_ account: Account) -> some View {
        if model.isLoadingRepos {
            VStack(spacing: 10) {
                Spacer()
                ProgressView("Loading repos for \(account.alias)…")
                repoRefreshStatus
                Spacer()
            }
                .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            VStack(spacing: 0) {
                repoListHeader
                Divider().overlay(theme.border)
                ScrollView {
                    if model.filteredRepos.isEmpty {
                        repoListEmptyState
                    } else {
                        LazyVStack(spacing: 2) {
                            ForEach(model.filteredRepos) { repo in repoRow(repo, account: account) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(minHeight: 240)
            .background(theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .sheet(item: $commitTarget) { target in commitSheet(target) }
            .confirmationDialog(
                "Push this repository to GitHub?",
                isPresented: Binding(get: { pushTarget != nil },
                                     set: { if !$0 { pushTarget = nil } }),
                presenting: pushTarget
            ) { target in
                Button("Push to GitHub") {
                    let target = target
                    pushTarget = nil
                    Task { await model.push(target.repo, in: target.account) }
                }
                Button("Cancel", role: .cancel) {
                    pushTarget = nil
                }
            } message: { target in
                Text("This will run git push for “\(target.repo.name)” in \(target.account.alias)'s folder. Make sure the local commits and branch are ready to publish.")
            }
            .confirmationDialog(
                "Move this folder to Trash?",
                isPresented: Binding(get: { deleteTarget != nil },
                                     set: { if !$0 { deleteTarget = nil } }),
                presenting: deleteTarget
            ) { target in
                Button("Move to Trash", role: .destructive) {
                    let target = target; deleteTarget = nil
                    Task { await model.deleteLocalFolder(target.repo, in: target.account) }
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: { target in
                Text("“\(target.repo.name)” in \(target.account.alias)'s folder will be moved to the Trash (recoverable). The GitHub repository is NOT affected.")
            }
        }
    }

    var repoSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textMuted)
            TextField("Wild search repos…  (part of a name, glob like m*ger, or fuzzy “mgm”)",
                      text: $model.repoSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !model.repoSearch.isEmpty {
                Text("\(model.filteredRepos.count)/\(model.repos.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Button { model.repoSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .tooltip("Clear search")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(theme.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .strokeBorder(theme.border, lineWidth: 1))
    }

    @ViewBuilder
    var repoListEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.repos.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(theme.textTertiary)
            Text(model.repos.isEmpty
                 ? "No repositories loaded yet."
                 : "No repositories match “\(model.repoSearch)”.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textMuted)
            if !model.repos.isEmpty {
                Button("Clear search") { model.repoSearch = "" }
                    .buttonStyle(SubtleButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    var repoListHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 18, height: 18)
            sortHeader("Repository", field: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: visWidth, height: 1)   // visibility column (icon-only, no title)
            sortHeader("Updated", field: .updated)
                .frame(width: updatedWidth, alignment: .leading)
            Text("Actions").frame(width: actionsWidth, alignment: .trailing)
        }
        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.textMuted)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(height: 28)
    }

    /// A clickable column title: click toggles ASC/DESC, click another column to
    /// switch. An arrow shows the active column and direction.
    func sortHeader(_ title: String, field: RepoSortField) -> some View {
        let active = model.repoSortField == field
        return Button {
            model.sortBy(field)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: active ? (model.repoSortAscending ? "chevron.up" : "chevron.down")
                                         : "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(active ? theme.accent : theme.textMuted.opacity(0.45))
            }
            .foregroundStyle(active ? theme.text : theme.textMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func repoRow(_ repo: Repo, account: Account) -> some View {
        let selected = model.selectedRepo == repo.id
        let status = model.repoStatuses[repo.id]
        let cloned = model.isCloned(repo)
        let conflict = model.folderConflict(repo)
        let attention = status?.needsAttention ?? false
        let shared = isShared(repo)
        return HStack(spacing: 10) {
            Image(systemName: repoIcon(cloned: cloned, conflict: conflict))
                .foregroundStyle(repoIconColor(cloned: cloned, attention: attention, conflict: conflict))
                .frame(width: 18)
                .tooltip(cloneIconHelp(cloned: cloned, status: status, conflict: conflict))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(repo.name).font(.system(size: 13, weight: .medium))
                    if shared { sharedBadge(repo.owner) }
                    if let conflict { folderConflictBadge(conflict) }
                    if let status { statusBadges(status, repo: repo, account: account) }
                }
                if let d = repo.description, !d.isEmpty {
                    Text(d).font(.system(size: 11)).foregroundStyle(theme.textMuted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            visBadge(repo.visibility)
                .frame(width: visWidth, alignment: .center)
            Text(formattedUpdated(repo.updatedAt))
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.textMuted)
                .lineLimit(1)
                .frame(width: updatedWidth, alignment: .leading)
            rowActions(repo, account: account).frame(width: actionsWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(selectionBackground(selected))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border.opacity(0.75))
                .frame(height: 1)
                .padding(.leading, 30) // keep icon gutter visually clean
                .padding(.trailing, 12)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedRepo = repo.id }
        .padding(.horizontal, 4)
    }

    func repoIcon(cloned: Bool, conflict: AppModel.RepoFolderConflict?) -> String {
        if cloned { return "internaldrive.fill" }
        if conflict != nil { return "exclamationmark.triangle.fill" }
        return "cloud"
    }

    func repoIconColor(cloned: Bool,
                               attention: Bool,
                               conflict: AppModel.RepoFolderConflict?) -> Color {
        if conflict != nil { return theme.warning }
        if cloned { return attention ? theme.warning : theme.accent }
        return theme.textMuted
    }

    /// A repo is "shared" when its owner is not the selected account — i.e. you
    /// were added as a collaborator. Own repos return false (no badge).
    func isShared(_ repo: Repo) -> Bool {
        guard let me = model.selectedAccount?.alias else { return false }
        return repo.owner.caseInsensitiveCompare(me) != .orderedSame
    }

    /// Grey two-people icon marking a repo shared with you by another account.
    /// The owner login lives in the tooltip to keep the row uncluttered.
    func sharedBadge(_ owner: String) -> some View {
        Image(systemName: "person.2.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.textMuted)
            .tooltip("Shared by \(owner) — you're a collaborator")
            .accessibilityLabel("Shared by \(owner)")
    }

    func folderConflictBadge(_ conflict: AppModel.RepoFolderConflict) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(theme.warning)
            .tooltip(conflict.shortHelp)
            .accessibilityLabel(conflict.shortHelp)
    }

    /// Visibility as a glanceable icon: amber lock = private, green globe =
    /// public, grey building = internal. The word stays in the tooltip.
    @ViewBuilder
    func visBadge(_ raw: String) -> some View {
        switch raw.lowercased() {
        case "private":
            visIcon("lock.fill", theme.warning, "Private")
        case "public":
            visIcon("globe", theme.success, "Public")
        case "internal":
            visIcon("building.2.fill", theme.textMuted, "Internal")
        default:
            Text(raw.lowercased())
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.textMuted)
        }
    }

    func visIcon(_ name: String, _ color: Color, _ label: String) -> some View {
        Label(label, systemImage: name)
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .tooltip(label)
            .accessibilityLabel("Visibility: \(label)")
    }

    /// VS-Code-style cues: amber pencil = uncommitted changes (clickable for a
    /// file summary), purple up-arrow = unpushed commits, amber down-arrow = behind
    /// remote, green check = current after a live upstream fetch.
    @ViewBuilder
    func statusBadges(_ status: RepoStatus, repo: Repo, account: Account) -> some View {
        HStack(spacing: 4) {
            if status.isDiverged {
                statusIconPill("exclamationmark.triangle.fill", theme.warning, theme.warningSubtle,
                               help: "Local and remote both have commits. Pull or rebase before pushing.")
            }
            if status.changedFiles > 0 {
                ChangeSummaryButton(repo: repo, account: account, count: status.changedFiles)
            }
            if status.ahead > 0 {
                statusPill("arrow.up", status.ahead, theme.accent, theme.accentSubtle,
                           help: "\(plural(status.ahead, "local commit")) not pushed yet")
            }
            if status.behind > 0 {
                statusPill("arrow.down", status.behind, theme.warning, theme.warningSubtle,
                           help: "\(plural(status.behind, "commit")) behind upstream remote\(remoteCheckContext(status))")
            }
            remoteStateBadge(status)
        }
    }

    func statusPill(_ icon: String, _ count: Int, _ tint: Color, _ fill: Color, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text("\(count)").font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(tint)
        .padding(.vertical, 1).padding(.horizontal, 5)
        .background(fill)
        .clipShape(Capsule())
        .tooltip(help)
    }

    func statusIconPill(_ icon: String, _ tint: Color, _ fill: Color, help: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(.vertical, 2).padding(.horizontal, 5)
            .background(fill)
            .clipShape(Capsule())
            .tooltip(help)
    }

    @ViewBuilder
    func remoteStateBadge(_ status: RepoStatus) -> some View {
        switch status.remoteState {
        case .checked where status.isCleanAndCurrent:
            statusIconPill("checkmark", theme.success, theme.successSubtle,
                           help: "Up to date with upstream remote (checked with git fetch)")
        case .failed(let message):
            statusIconPill("exclamationmark.triangle.fill", theme.error, theme.errorSubtle,
                           help: "Remote check failed: \(message)")
        case .noUpstream:
            statusIconPill("questionmark.circle.fill", theme.textMuted, theme.surfaceMuted,
                           help: "No upstream branch configured; cannot compare this clone with GitHub")
        case .upstreamGone:
            statusIconPill("exclamationmark.triangle.fill", theme.warning, theme.warningSubtle,
                           help: "The upstream branch no longer exists on the remote (deleted or renamed). Push the branch again or re-set its upstream.")
        case .checked, .unchecked:
            EmptyView()
        }
    }

    func remoteCheckContext(_ status: RepoStatus) -> String {
        switch status.remoteState {
        case .checked:
            return " (checked with git fetch)"
        case .failed:
            return " (from local tracking data; live remote check failed)"
        case .unchecked:
            return " (from local tracking data)"
        case .noUpstream, .upstreamGone:
            return ""
        }
    }

    func cloneIconHelp(cloned: Bool,
                               status: RepoStatus?,
                               conflict: AppModel.RepoFolderConflict?) -> String {
        if let conflict { return conflict.shortHelp }
        guard cloned else { return "Remote only" }
        guard let status else { return "Cloned locally — status pending" }
        if status.isCleanAndCurrent {
            return "Cloned locally — up to date with upstream remote"
        }
        var parts: [String] = []
        if status.changedFiles > 0 { parts.append(plural(status.changedFiles, "uncommitted change")) }
        if status.isDiverged {
            parts.append("diverged: \(plural(status.ahead, "commit")) to push, \(plural(status.behind, "commit")) to pull")
        } else {
            if status.ahead > 0 { parts.append(plural(status.ahead, "commit") + " to push") }
            if status.behind > 0 { parts.append(plural(status.behind, "commit") + " to pull") }
        }
        switch status.remoteState {
        case .failed(let message):
            parts.append("remote check failed: \(message)")
        case .noUpstream:
            parts.append("no upstream branch")
        case .upstreamGone:
            parts.append("upstream branch no longer exists on the remote")
        case .unchecked where parts.isEmpty:
            parts.append("clean; remote not checked yet")
        case .checked, .unchecked:
            break
        }
        return "Cloned locally — " + parts.joined(separator: ", ")
    }

    func plural(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    func openMenu(_ repo: Repo, account: Account) -> some View {
        ActionPopoverButton(systemName: "folder", help: "Open…") { isPresented in
            VStack(alignment: .leading, spacing: 4) {
                openPopoverButton("Finder", systemImage: "folder") {
                    isPresented.wrappedValue = false
                    model.openLocalFolder(repo, in: account)
                }

                openPopoverButton("GitHub", systemImage: "globe") {
                    isPresented.wrappedValue = false
                    model.openGitHubRepo(repo)
                }

                if preferredEditor == .none {
                    openPopoverDisabledRow("Editor not configured",
                                           systemImage: "chevron.left.forwardslash.chevron.right")
                } else {
                    openPopoverButton(preferredEditor.displayName(customAppName: customEditorName),
                                      systemImage: "chevron.left.forwardslash.chevron.right") {
                        isPresented.wrappedValue = false
                        Task {
                            await model.openInEditor(repo,
                                                     in: account,
                                                     editor: preferredEditor,
                                                     customAppName: customEditorName)
                        }
                    }
                }

                if preferredTerminal == .none {
                    openPopoverDisabledRow("Terminal not configured", systemImage: "terminal")
                } else {
                    openPopoverButton(preferredTerminal.displayName(customAppName: customTerminalName),
                                      systemImage: "terminal") {
                        isPresented.wrappedValue = false
                        Task {
                            await model.openInTerminal(repo,
                                                       in: account,
                                                       terminal: preferredTerminal,
                                                       customAppName: customTerminalName)
                        }
                    }
                }
            }
            .padding(8)
            .frame(width: 220)
            .background(theme.surface)
        }
    }

    func openPopoverButton(_ title: String,
                                   systemImage: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(theme.surfaceMuted.opacity(0.001))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }

    func openPopoverDisabledRow(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .opacity(0.75)
    }

    @ViewBuilder
    func rowActions(_ repo: Repo, account: Account) -> some View {
        HStack(spacing: 7) {
            if model.isCloned(repo) {
                openMenu(repo, account: account)
                iconButton("arrow.down", "Pull (git pull)") { Task { await model.pull(repo, in: account) } }
                iconButton("pencil", "Commit all changes…") {
                    commitMessage = ""
                    commitTarget = RepoActionTarget(repo: repo, account: account)
                }
                iconButton("arrow.up", "Push (git push)") {
                    pushTarget = RepoActionTarget(repo: repo, account: account)
                }
                iconButton("trash", "Move local folder to Trash (recoverable)",
                           tint: theme.error, fill: theme.errorSubtle) {
                    deleteTarget = RepoActionTarget(repo: repo, account: account)
                }
            } else if let conflict = model.folderConflict(repo) {
                disabledIconChip("exclamationmark.triangle.fill",
                                 conflict.shortHelp,
                                 tint: theme.warning,
                                 fill: theme.warningSubtle)
            } else {
                iconButton("square.and.arrow.down", "Clone into the account folder") {
                    Task { await model.clone(repo, in: account) }
                }
            }
        }
        // A pull/push/commit/clone is already running for this repo — block a second
        // one rather than let two git processes collide on the same local folder.
        .disabled(model.isRepoActionBusy(repo))
    }

    func iconButton(_ systemName: String, _ help: String,
                            tint: Color? = nil, fill: Color? = nil,
                            _ action: @escaping () -> Void) -> some View {
        ActionIconButton(systemName: systemName, help: help, tint: tint, fill: fill, action: action)
    }

    func disabledIconChip(_ systemName: String,
                                  _ help: String,
                                  tint: Color,
                                  fill: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 26)
            .background(fill.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1))
            .tooltip(help)
            .accessibilityLabel(help)
    }

    func commitSheet(_ target: RepoActionTarget) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Commit all changes in \(target.repo.name)").font(Theme.title(16))
            Text(target.account.folder)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Runs:  git add -A  &&  git commit -m …")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textMuted)
            TextField("Commit message", text: $commitMessage)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
            HStack {
                Spacer()
                Button("Cancel") { commitTarget = nil }
                    .buttonStyle(SubtleButtonStyle())
                Button("Commit") {
                    let message = commitMessage
                    let target = target
                    commitTarget = nil
                    Task { await model.commit(target.repo, message: message, in: target.account) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .background(theme.surface)
    }

    var cloneBar: some View {
        HStack(spacing: 16) {
            Label("Remote only", systemImage: "cloud").foregroundStyle(theme.textMuted)
            Label("Cloned locally", systemImage: "internaldrive.fill").foregroundStyle(theme.accent)
            Spacer()
            repoRefreshStatus
            Text(model.repoSearch.isEmpty
                 ? "\(model.repos.count) repo(s)"
                 : "\(model.filteredRepos.count) of \(model.repos.count) repo(s)")
                .foregroundStyle(theme.textMuted)
        }
        .font(.system(size: 11, weight: .medium))
    }

    @ViewBuilder
    var repoRefreshStatus: some View {
        if model.isLoadingRepos || model.isRefreshingRepos {
            Label("Refreshing repos…", systemImage: "arrow.clockwise")
                .foregroundStyle(theme.warning)
                .lineLimit(1)
                .tooltip("Refreshing GitHub repo list")
        } else if model.isCheckingRepoRemotes {
            Label("Checking cloned remotes…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(theme.warning)
                .lineLimit(1)
                .tooltip("Fetching upstream remotes for cloned repos")
        } else if let message = model.repoRefreshMessage, !message.isEmpty {
            let failed = message.localizedCaseInsensitiveContains("failed")
            Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failed ? theme.error : theme.success)
                .lineLimit(1)
                .tooltip(message)
        }
    }

    var lastLogLine: String? {
        model.log
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init)
    }

    var outputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Title doubles as the expand/collapse toggle.
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { outputExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: outputExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("OUTPUT")
                            .font(.system(size: 11, weight: .bold)).tracking(0.6)
                    }
                    .foregroundStyle(theme.textMuted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !outputExpanded, let last = lastLogLine {
                    Text(last)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .opacity(statusLineVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.45), value: statusLineVisible)
                }

                Spacer(minLength: 0)

                // On-demand raw `gh auth status`, dumped into the log below.
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { outputExpanded = true }
                    Task { await model.logAuthStatus() }
                } label: {
                    Label("gh auth status", systemImage: "person.badge.key")
                        .font(.system(size: 10, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .tooltip("Run gh auth status and show the result in the Output log")
            }

            if outputExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.log.isEmpty ? "—" : model.log)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                        // Invisible tail the viewport scrolls to, so the newest log
                        // line is always visible instead of hidden below the fold.
                        Color.clear.frame(height: 1).id(Self.logBottomAnchor)
                    }
                    .frame(height: 112)
                    .background(theme.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1))
                    .padding(.top, 6)
                    .onChange(of: model.log) { _ in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.logBottomAnchor, anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo(Self.logBottomAnchor, anchor: .bottom) }
                }
            }
        }
        // Every new log line refreshes the collapsed status: show it, then fade
        // after a delay — unless it's an error/warning, which stays pinned.
        .onChange(of: model.log) { _ in refreshStatusLine() }
    }

    /// Shows the collapsed Output status line and schedules it to fade out, so a
    /// finished "Opening…"/"Cloning…" message doesn't linger and look in-progress.
    /// Failures/warnings are left pinned until the next action replaces them.
    func refreshStatusLine() {
        statusFadeTask?.cancel()
        statusLineVisible = true
        guard !model.lastLogWasError else { statusFadeTask = nil; return }
        statusFadeTask = Task { @MainActor in
            try? await Task.sleep(for: Self.statusFadeDelay)
            guard !Task.isCancelled else { return }
            statusLineVisible = false
        }
    }
}
