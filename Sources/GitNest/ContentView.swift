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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let account = accountManager.selectedAccount {
                header(account)
                Divider().overlay(theme.border)
                if !repoManager.isLoadingRepos && !repoManager.repos.isEmpty {
                    repoSearchBar
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
                    customTerminalName: customTerminalName
                )
                cloneBar
            } else {
                Spacer()
                Text("Select an account on the left.")
                    .font(.system(size: 14)).foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            Divider().overlay(theme.border)
            LogOutputView(outputExpanded: $outputExpanded)
        }
        .padding(18)
        .background(theme.surface)
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
                .disabled(!ready || projectWorkflow.isInitializingProject || repoManager.isLoadingRepos || projectWorkflow.isForkingProject)

                Button {
                    showForkSheet = true
                    forkAddress = ""
                } label: {
                    Label("Fork project", systemImage: "tuningfork")
                }
                .buttonStyle(PrimaryButtonStyle())
                .tooltip(gateHint ?? "Fork a GitHub repository into this account and clone it")
                .disabled(!ready || projectWorkflow.isInitializingProject || repoManager.isLoadingRepos || projectWorkflow.isForkingProject)

                Button {
                    Task { await repoManager.loadRepos(for: account) }
                } label: {
                    Label("Load repos", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(PrimaryButtonStyle())
                .tooltip(gateHint ?? "List every repo \(account.alias) owns (via gh)")
                .disabled(!ready || repoManager.isLoadingRepos || projectWorkflow.isInitializingProject || projectWorkflow.isForkingProject)
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
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textMuted)
            TextField("Wild search repos…  (part of a name, glob like m*ger, or fuzzy “mgm”)",
                      text: $repoManager.repoSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
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

    // MARK: Clone bar

    private var cloneBar: some View {
        HStack(spacing: 16) {
            Label("Remote only", systemImage: "cloud").foregroundStyle(theme.textMuted)
            Label("Cloned locally", systemImage: "internaldrive.fill").foregroundStyle(theme.accent)
            Spacer()
            repoRefreshStatus
            Text(repoManager.repoSearch.isEmpty
                 ? "\(repoManager.repos.count) repo(s)"
                 : "\(repoManager.filteredRepos.count) of \(repoManager.repos.count) repo(s)")
                .foregroundStyle(theme.textMuted)
        }
        .font(.system(size: 11, weight: .medium))
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
