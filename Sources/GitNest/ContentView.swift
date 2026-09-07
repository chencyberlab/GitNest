import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var accountManager: AccountManager
    @EnvironmentObject var alertStore: AlertStore
    @StateObject var tooltip = TooltipController()

    // Project sheets
    @State var initPlan: ProjectInitPlan?
    @State var initVisibility: RepoVisibilityChoice = .private
    @State var moveOriginalToTrash = false
    @State var showForkSheet = false
    @State var forkAddress: String = ""

    // Repo action confirmation targets
    @State var commitTarget: RepoActionTarget?
    @State var commitMessage: String = ""
    @State var deleteTarget: RepoActionTarget?
    @State var pushTarget: RepoActionTarget?

    // Sidebar state
    @State var ghLoginTarget: Account?
    @State var accountSearch: String = ""
    @State var expandedAccountAliases: Set<String> = []
    @State var showSettings = false

    /// Persisted appearance choice: "system" | "light" | "dark".
    @AppStorage("appearancePreference") var appearancePreference: String = "system"

    /// Persisted colour-scheme palette choice.
    @AppStorage("colorThemeID") var colorThemeID: String = ColorThemePalette.gitNest.id

    /// Output pane starts collapsed to save vertical space; choice is remembered.
    @AppStorage("outputExpanded") var outputExpanded: Bool = false

    /// GitHub repo-list auto-refresh interval, in seconds. 0 disables it.
    @AppStorage("repoAutoRefreshSeconds") var repoAutoRefreshSeconds: Int = 300

    /// Account card SSH/gh readiness loading mode.
    @AppStorage("accountStatusLoadMode") var accountStatusLoadModeRaw: String = AccountStatusLoadMode.smart.rawValue

    /// Preferred GUI editor for the "Open in Editor" button, plus the custom app
    /// name used when the choice is `.custom`.
    @AppStorage("preferredEditor") var preferredEditorRaw: String = PreferredEditor.none.rawValue
    @AppStorage("customEditorAppName") var customEditorName: String = ""

    /// Preferred GUI terminal for the cloned-repo Open menu, plus the custom app
    /// name used when the choice is `.custom`.
    @AppStorage("preferredTerminal") var preferredTerminalRaw: String = PreferredTerminal.none.rawValue
    @AppStorage("customTerminalAppName") var customTerminalName: String = ""

    private var accountStatusLoadMode: AccountStatusLoadMode {
        AccountStatusLoadMode(rawValue: accountStatusLoadModeRaw) ?? .smart
    }

    private var preferredEditor: PreferredEditor {
        PreferredEditor(rawValue: preferredEditorRaw) ?? .none
    }

    private var preferredTerminal: PreferredTerminal {
        PreferredTerminal(rawValue: preferredTerminalRaw) ?? .none
    }

    /// Resolved theme for this view. Injected into the environment so sheets,
    /// popovers and reusable button styles all see the same palette.
    var theme: Theme {
        Theme(palette: ColorThemePalette.palette(for: colorThemeID) ?? .gitNest)
    }

    var resolvedScheme: ColorScheme? {
        switch appearancePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil          // follow system
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                accountSearch: $accountSearch,
                expandedAccountAliases: $expandedAccountAliases,
                ghLoginTarget: $ghLoginTarget,
                showSettings: $showSettings,
                appearancePreference: $appearancePreference,
                colorThemeID: $colorThemeID,
                repoAutoRefreshSeconds: $repoAutoRefreshSeconds,
                accountStatusLoadModeRaw: $accountStatusLoadModeRaw,
                preferredEditorRaw: $preferredEditorRaw,
                customEditorName: $customEditorName,
                preferredTerminalRaw: $preferredTerminalRaw,
                customTerminalName: $customTerminalName
            )
        } detail: {
            DetailView(
                commitTarget: $commitTarget,
                commitMessage: $commitMessage,
                pushTarget: $pushTarget,
                deleteTarget: $deleteTarget,
                initPlan: $initPlan,
                initVisibility: $initVisibility,
                moveOriginalToTrash: $moveOriginalToTrash,
                showForkSheet: $showForkSheet,
                forkAddress: $forkAddress,
                outputExpanded: $outputExpanded,
                preferredEditor: preferredEditor,
                preferredTerminal: preferredTerminal,
                customEditorName: customEditorName,
                customTerminalName: customTerminalName
            )
        }
        .frame(minWidth: 920, minHeight: 580)
        .navigationTitle("GitNest")
        .tint(theme.accent)
        .preferredColorScheme(resolvedScheme)
        // Recolour the title bar so third-party palettes (Dracula, Cyberpunk, …)
        // match the content area instead of staying system black/white. The default
        // GitNest theme leaves the window tokens nil (OS-following), so we apply no
        // background — keeping `.automatic` visibility makes that a true no-op.
        .toolbarBackground(theme.hasCustomWindowChrome ? theme.windowChromeBackground : .clear,
                           for: .windowToolbar)
        .toolbarBackground(theme.hasCustomWindowChrome ? .visible : .automatic,
                           for: .windowToolbar)
        .coordinateSpace(name: TooltipController.space)
        .overlay { TooltipOverlay() }
        .environmentObject(tooltip)
        .environment(\.theme, theme)
        .onAppear {
            model.startLifecycle(statusMode: accountStatusLoadMode,
                                 repoAutoRefreshSeconds: repoAutoRefreshSeconds)
        }
        .onChange(of: repoAutoRefreshSeconds) { seconds in
            model.configureRepoAutoRefresh(seconds: seconds)
        }
        .onChange(of: accountStatusLoadModeRaw) { _ in
            model.configureAccountStatusLoadMode(accountStatusLoadMode)
            accountManager.refreshAll(statusMode: accountStatusLoadMode)
        }
        .sheet(item: $initPlan) { plan in
            InitProjectSheet(
                plan: plan,
                initVisibility: $initVisibility,
                moveOriginalToTrash: $moveOriginalToTrash,
                initPlan: $initPlan
            )
            .gitNestEnvironment(model)
        }
        .sheet(isPresented: $showForkSheet) {
            ForkProjectSheet(
                forkAddress: $forkAddress,
                showForkSheet: $showForkSheet
            )
            .gitNestEnvironment(model)
        }
        .alert(
            pullAlertTitle,
            isPresented: Binding(
                get: { alertStore.pullWarning != nil },
                set: { if !$0 { alertStore.dismissPullWarning() } }
            )
        ) {
            Button("OK") { alertStore.dismissPullWarning() }
        } message: {
            Text(alertStore.pullWarning?.message ?? "")
        }
    }

    /// Pull-failure alert title, scoped to the repo that failed when known.
    var pullAlertTitle: String {
        guard let name = alertStore.pullWarning?.repoName, !name.isEmpty else {
            return "Pull couldn't complete"
        }
        return "Pull couldn't complete — \(name)"
    }
}

/// Detail pane: selected-account header + repo list + output log.
private struct DetailView: View {
    @EnvironmentObject var accountManager: AccountManager
    @EnvironmentObject var repoManager: RepoManager
    @EnvironmentObject var repoActionCoordinator: RepoActionCoordinator
    @EnvironmentObject var projectWorkflow: ProjectWorkflow
    @EnvironmentObject var alertStore: AlertStore
    @Environment(\.theme) private var theme

    @Binding var commitTarget: RepoActionTarget?
    @Binding var commitMessage: String
    @Binding var pushTarget: RepoActionTarget?
    @Binding var deleteTarget: RepoActionTarget?

    @Binding var initPlan: ProjectInitPlan?
    @Binding var initVisibility: RepoVisibilityChoice
    @Binding var moveOriginalToTrash: Bool
    @Binding var showForkSheet: Bool
    @Binding var forkAddress: String

    @Binding var outputExpanded: Bool

    let preferredEditor: PreferredEditor
    let preferredTerminal: PreferredTerminal
    let customEditorName: String
    let customTerminalName: String

    @FocusState private var repoSearchFocused: Bool
    @FocusState private var repoListFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let account = accountManager.selectedAccount {
                header(account)
                ThemeDivider()
                if !repoManager.isLoadingRepos && !repoManager.repos.isEmpty {
                    repoSearchBar
                    attentionStrip
                }
                RepoListView(
                    account: account,
                    commitTarget: $commitTarget,
                    commitMessage: $commitMessage,
                    pushTarget: $pushTarget,
                    deleteTarget: $deleteTarget,
                    preferredEditor: preferredEditor,
                    preferredTerminal: preferredTerminal,
                    customEditorName: customEditorName,
                    customTerminalName: customTerminalName,
                    listFocused: $repoListFocused
                )
                cloneBar
            } else {
                emptyAccountState
            }
            ThemeDivider()
            LogOutputView(outputExpanded: $outputExpanded)
        }
        .padding(18)
        .background(theme.surface)
        .background(repoListKeyHandlers(for: accountManager.selectedAccount))
    }

    // MARK: Empty state

    /// Shown when no account is selected. Mirrors the repo-list empty state: an
    /// SF Symbol, a one-line hint, and a nudge toward the action that fixes it.
    private var emptyAccountState: some View {
        // Scrollable on purpose: a macOS NavigationSplitView only gives the sidebar
        // its title-bar safe-area inset while the detail column holds a scroll view.
        // Every other detail state has one (repo list, expanded output); without one
        // here the whole sidebar slid ~40pt up and "GitNest / Beta" collided with the
        // traffic lights. `minHeight` keeps the content centred exactly as before —
        // it fills the pane, so nothing ever actually scrolls.
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 30))
                        .foregroundStyle(theme.textTertiary)
                    Text("No account selected")
                        .font(Theme.title(15))
                        .foregroundStyle(theme.text)
                    Text("Pick an account on the left to see its repositories.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private func header(_ account: Account) -> some View {
        let ready = accountManager.accountReady(account)
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
                .disabled(!ready || projectWorkflow.isInitializingProject || repoManager.isBusyWithVisibleRepoLoad || projectWorkflow.isForkingProject)

                Button {
                    showForkSheet = true
                    forkAddress = ""
                } label: {
                    Label("Fork project", systemImage: "tuningfork")
                }
                .buttonStyle(PrimaryButtonStyle())
                .tooltip(gateHint ?? "Fork a GitHub repository into this account and clone it")
                .disabled(!ready || projectWorkflow.isInitializingProject || repoManager.isBusyWithVisibleRepoLoad || projectWorkflow.isForkingProject)

                Button {
                    Task { await repoManager.loadRepos(for: account) }
                } label: {
                    Label("Load repos", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(PrimaryButtonStyle())
                .tooltip(gateHint ?? "List every repo \(account.alias) owns (via gh)")
                .disabled(!ready || repoManager.isBusyWithVisibleRepoLoad || projectWorkflow.isInitializingProject || projectWorkflow.isForkingProject)
            }
        }
    }

    /// Why the action buttons are greyed out (nil once the account is ready) —
    /// surfaced as the buttons' tooltip so the disabled state isn't a mystery.
    private func connectionGateHint(_ account: Account) -> String? {
        if accountManager.accountReady(account) { return nil }
        if accountManager.accountChecking(account) {
            return "Checking SSH and GitHub connection for \(account.alias)…"
        }
        if !accountManager.accountStatusKnown(account) {
            return "Connection status has not been checked for \(account.alias) yet. Select the card or press Refresh."
        }
        return "SSH or GitHub isn't ready for \(account.alias). Fix it on the account card (SSH / GitHub login), then Refresh."
    }

    private func chooseInitFolder(for account: Account) {
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
        Task { initPlan = await projectWorkflow.makeInitPlan(sourceURL: url, account: account) }
    }

    // MARK: Search

    private var repoSearchBar: some View {
        HStack(spacing: 8) {
            Button {
                repoSearchFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(repoSearchFocused ? theme.accent : theme.textMuted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .tooltip("Focus repo search (⌘F)")

            TextField("Filter repos — name, glob (m*ger), or fuzzy “mgm”",
                      text: $repoManager.repoSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($repoSearchFocused)
                .onExitCommand {
                    if !repoManager.repoSearch.isEmpty {
                        repoManager.repoSearch = ""
                    } else {
                        repoSearchFocused = false
                        repoListFocused = true
                    }
                }
            if !repoManager.repoSearch.isEmpty {
                Text("\(repoManager.filteredRepos.count)/\(repoManager.repos.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Button { repoManager.repoSearch = "" } label: {
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

    // MARK: Attention strip

    @ViewBuilder
    private var attentionStrip: some View {
        let summary = repoManager.attentionSummary
        if !summary.isEmpty {
            HStack(spacing: 8) {
                Text("Needs attention")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textMuted)
                ForEach(RepoAttentionKind.allCases) { kind in
                    let count = summary.count(for: kind)
                    if count > 0 {
                        attentionChip(kind, count: count)
                    }
                }
                Spacer(minLength: 0)
                if repoManager.attentionFilter != nil {
                    Button("Show all") {
                        repoManager.attentionFilter = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .tooltip("Clear the attention filter")
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func attentionChip(_ kind: RepoAttentionKind, count: Int) -> some View {
        let selected = repoManager.attentionFilter == kind
        return Button {
            repoManager.toggleAttentionFilter(kind)
        } label: {
            HStack(spacing: 4) {
                Text(kind.title)
                Text("\(count)")
                    .fontWeight(.semibold)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selected ? theme.primaryText : theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? theme.primary : theme.surfaceMuted)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .tooltip(kind.help)
    }

    // MARK: Keyboard

    /// Invisible shortcut targets so open/commit work even when focus is on the
    /// search field. Arrow selection uses `onMoveCommand` on the focused list.
    @ViewBuilder
    private func repoListKeyHandlers(for account: Account?) -> some View {
        if let account {
            ZStack {
                Button("Open selected repo") {
                    openSelectedRepo(in: account)
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button("Commit selected repo") {
                    beginCommitSelected(in: account)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            .opacity(0.01)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private func openSelectedRepo(in account: Account) {
        guard let repo = selectedVisibleRepo() else { return }
        guard repoManager.isCloned(repo) else { return }
        if preferredEditor != .none {
            Task {
                await repoActionCoordinator.openInEditor(repo,
                                                         in: account,
                                                         editor: preferredEditor,
                                                         customAppName: customEditorName)
            }
        } else {
            repoActionCoordinator.openLocalFolder(repo, in: account)
        }
    }

    private func beginCommitSelected(in account: Account) {
        guard let repo = selectedVisibleRepo(),
              repoManager.isCloned(repo),
              (repoManager.repoStatuses[repo.id]?.changedFiles ?? 0) > 0,
              !repoActionCoordinator.isRepoActionBusy(repo) else { return }
        commitMessage = ""
        commitTarget = RepoActionTarget(repo: repo, account: account)
    }

    private func selectedVisibleRepo() -> Repo? {
        guard let id = repoManager.selectedRepo else { return nil }
        return repoManager.filteredRepos.first(where: { $0.id == id })
            ?? repoManager.repos.first(where: { $0.id == id })
    }

    // MARK: Clone bar

    private var cloneBar: some View {
        HStack(spacing: 16) {
            Label("Remote only", systemImage: "cloud").foregroundStyle(theme.textMuted)
            Label("Cloned locally", systemImage: "internaldrive.fill").foregroundStyle(theme.accent)
            Spacer()
            repoRefreshStatus
            Text(repoListCountLabel)
                .foregroundStyle(theme.textMuted)
        }
        .font(.system(size: 11, weight: .medium))
    }

    private var repoListCountLabel: String {
        let shown = repoManager.filteredRepos.count
        let total = repoManager.repos.count
        if repoManager.attentionFilter != nil || !repoManager.repoSearch.isEmpty {
            return "\(shown) of \(total) repo(s)"
        }
        return "\(total) repo(s)"
    }

    @ViewBuilder
    private var repoRefreshStatus: some View {
        if repoManager.isLoadingRepos || repoManager.isRefreshingRepos {
            Label("Refreshing repos…", systemImage: "arrow.clockwise")
                .foregroundStyle(theme.warning)
                .lineLimit(1)
                .tooltip("Refreshing GitHub repo list")
        } else if repoManager.isCheckingRepoRemotes {
            Label("Checking cloned remotes…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(theme.warning)
                .lineLimit(1)
                .tooltip("Fetching upstream remotes for cloned repos")
        } else if let message = repoManager.repoRefreshMessage, !message.isEmpty {
            let failed = message.localizedCaseInsensitiveContains("failed")
            Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failed ? theme.error : theme.success)
                .lineLimit(1)
                .tooltip(message)
        }
    }
}
