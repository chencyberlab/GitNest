import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @StateObject var tooltip = TooltipController()
    @State var commitTarget: RepoActionTarget?
    @State var commitMessage: String = ""
    @State var deleteTarget: RepoActionTarget?
    @State var pushTarget: RepoActionTarget?
    @State var ghLoginTarget: Account?
    @State var initPlan: ProjectInitPlan?
    @State var initVisibility: RepoVisibilityChoice = .private
    @State var moveOriginalToTrash = false
    @State var showForkSheet = false
    @State var forkAddress: String = ""
    @State var accountSearch: String = ""
    @State var expandedAccountAliases: Set<String> = []
    @State var showSettings = false

    struct RepoActionTarget: Identifiable {
        let repo: Repo
        let account: Account

        var id: String { "\(account.alias)|\(repo.id)" }
    }

    // Drag-to-reorder state for account cards. The model order is left untouched
    // while dragging — the dragged card follows the finger, the other cards part
    // to open a gap, and the actual reorder is committed once on drop. Frames are
    // measured in the `accountListSpace` coordinate space so the math works with
    // both collapsed and expanded (variable-height) cards.
    @State var draggingAlias: String?
    @State var dragTranslation: CGFloat = 0
    @State var dragStartMidY: CGFloat = 0
    @State var dragTargetIndex: Int?
    @State var dragStartOrder: [String] = []
    @State var dragStartFrames: [String: CGRect] = [:]
    @State var cardFrames: [String: CGRect] = [:]
    static let accountListSpace = "accountListSpace"

    /// Drives the fade of the collapsed Output status line. The full log in the
    /// expanded panel is unaffected — only this one-line summary fades out.
    @State var statusLineVisible = false
    @State var statusFadeTask: Task<Void, Never>?
    /// Seconds the status line stays before fading. Errors/warnings never fade.
    static let statusFadeDelay: Duration = .seconds(4)
    /// Identity of the invisible tail view the Output log auto-scrolls to.
    static let logBottomAnchor = "logBottom"

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

    /// Resolved theme for this view. Injected into the environment so sheets,
    /// popovers and reusable button styles all see the same palette.
    var theme: Theme {
        Theme(palette: ColorThemePalette.palette(for: colorThemeID) ?? .gitNest)
    }

    var preferredEditor: PreferredEditor {
        PreferredEditor(rawValue: preferredEditorRaw) ?? .none
    }

    var preferredTerminal: PreferredTerminal {
        PreferredTerminal(rawValue: preferredTerminalRaw) ?? .none
    }

    var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Beta \(version.nilIfEmpty ?? "1.0.0")"
    }

    enum AccountSummaryStatus {
        case loading
        case notLoaded
        case ready
        case partial
        case failed

        var help: String {
            switch self {
            case .loading: return "Loading SSH and GitHub status"
            case .notLoaded: return "Connection status not loaded"
            case .ready: return "SSH and GitHub are ready"
            case .partial: return "SSH or GitHub needs attention"
            case .failed: return "SSH and GitHub checks failed"
            }
        }
    }

    /// Parses the ISO-8601 timestamps returned by `gh` (e.g. 2026-06-02T16:40:31Z).
    static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Locale-aware date+time display. The pattern (field order, separators,
    /// 12/24-hour clock) is derived from the machine's current locale, and the
    /// value is shown in the local time zone.
    static let updatedDisplayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("yMd jm")
        return f
    }()

    func formattedUpdated(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        guard let date = Self.isoParser.date(from: raw) else {
            return String(raw.prefix(10))
        }
        return Self.updatedDisplayFormatter.string(from: date)
    }

    var filteredAccounts: [Account] {
        let query = accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.accounts }
        return model.accounts.filter { AccountSearch.matches(query: query, account: $0) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
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
            model.refreshAll(statusMode: accountStatusLoadMode)
        }
        .sheet(item: $initPlan) { plan in
            initProjectSheet(plan)
        }
        .sheet(isPresented: $showForkSheet) {
            forkProjectSheet
        }
        .alert(
            pullAlertTitle,
            isPresented: Binding(
                get: { model.pullWarning != nil },
                set: { if !$0 { model.pullWarning = nil } }
            )
        ) {
            Button("OK") { model.pullWarning = nil }
        } message: {
            Text(model.pullWarning?.message ?? "")
        }
    }

    /// Pull-failure alert title, scoped to the repo that failed when known.
    var pullAlertTitle: String {
        guard let name = model.pullWarning?.repoName, !name.isEmpty else {
            return "Pull couldn't complete"
        }
        return "Pull couldn't complete — \(name)"
    }

    // MARK: Appearance

    var resolvedScheme: ColorScheme? {
        switch appearancePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil          // follow system
        }
    }

    var appearanceIcon: String {
        switch appearancePreference {
        case "light": return "sun.max.fill"
        case "dark": return "moon.fill"
        default: return "circle.lefthalf.filled"
        }
    }

    var appearanceMenu: some View {
        Menu {
            Picker("Appearance", selection: $appearancePreference) {
                Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                Label("Light", systemImage: "sun.max").tag("light")
                Label("Dark", systemImage: "moon").tag("dark")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: appearanceIcon).foregroundStyle(theme.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tooltip("Appearance: \(appearancePreference.capitalized) — click to change")
    }

    // MARK: Settings (gear → popover)

    var settingsButton: some View {
        Button { showSettings.toggle() } label: {
            Image(systemName: "gearshape").font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .tooltip("Settings — account status, repo auto-refresh, and open actions")
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            settingsPopover
        }
    }

    var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings")
                    .font(Theme.title(15))
                    .foregroundStyle(theme.text)
                Spacer()
                Button { showSettings = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close settings")
            }

            settingsSection(title: "Account Status", help: accountStatusLoadMode.help) {
                Picker("Account status loading", selection: $accountStatusLoadModeRaw) {
                    ForEach(AccountStatusLoadMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            settingsSection(
                title: "Colour scheme",
                help: "Choose the accent and surface colours used throughout the app."
            ) {
                Picker("Colour scheme", selection: $colorThemeID) {
                    ForEach(allPalettes) { palette in
                        Text(palette.displayName).tag(palette.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            settingsSection(
                title: "Repo auto-refresh",
                help: "Auto-refreshes the accounts you've loaded. The account you're viewing uses this interval; background accounts and large repo lists back off automatically to stay light on the GitHub API."
            ) {
                Picker("Repo auto-refresh", selection: $repoAutoRefreshSeconds) {
                    Text("Off").tag(0)
                    Text("30 sec").tag(30)
                    Text("2 min").tag(120)
                    Text("5 min").tag(300)
                    Text("10 min").tag(600)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            settingsSection(
                title: "Open in Editor",
                help: "Adds an editor option to each cloned repo's Open menu. Open in Finder always stays available."
            ) {
                Picker("Preferred editor", selection: $preferredEditorRaw) {
                    ForEach(PreferredEditor.allCases) { editor in
                        Text(editor.menuTitle).tag(editor.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                if preferredEditor == .custom {
                    TextField("GUI app name (e.g. Sublime Text)", text: $customEditorName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
            }

            settingsSection(
                title: "Open in Terminal",
                help: "Adds a terminal option to each cloned repo's Open menu. Terminal apps are opened with the repo folder as the target."
            ) {
                Picker("Preferred terminal", selection: $preferredTerminalRaw) {
                    ForEach(PreferredTerminal.allCases) { terminal in
                        Text(terminal.menuTitle).tag(terminal.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                if preferredTerminal == .custom {
                    TextField("GUI app name (e.g. WezTerm)", text: $customTerminalName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
            }
        }
        .padding(18)
        .frame(width: 320)
    }

    @ViewBuilder
    func settingsSection<Content: View>(title: String,
                                                help: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text)
            content()
            Text(help)
                .font(.system(size: 10))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var accountStatusLoadMode: AccountStatusLoadMode {
        AccountStatusLoadMode(rawValue: accountStatusLoadModeRaw) ?? .smart
    }

    /// Brand selection background (replaces the system blue highlight).
    @ViewBuilder
    func selectionBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .fill(selected ? theme.accentSubtle : Color.clear)
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            }
    }

}
