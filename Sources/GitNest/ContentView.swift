import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var tooltip = TooltipController()
    @State private var commitTarget: Repo?
    @State private var commitMessage: String = ""
    @State private var deleteTarget: Repo?
    @State private var pushTarget: Repo?
    @State private var ghLoginTarget: Account?
    @State private var initPlan: ProjectInitPlan?
    @State private var initVisibility: RepoVisibilityChoice = .private
    @State private var moveOriginalToTrash = false
    @State private var showForkSheet = false
    @State private var forkAddress: String = ""
    @State private var accountSearch: String = ""
    @State private var expandedAccountAliases: Set<String> = []
    @State private var showSettings = false

    // Drag-to-reorder state for account cards. The model order is left untouched
    // while dragging — the dragged card follows the finger, the other cards part
    // to open a gap, and the actual reorder is committed once on drop. Frames are
    // measured in the `accountListSpace` coordinate space so the math works with
    // both collapsed and expanded (variable-height) cards.
    @State private var draggingAlias: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var dragStartMidY: CGFloat = 0
    @State private var dragTargetIndex: Int?
    @State private var dragStartOrder: [String] = []
    @State private var dragStartFrames: [String: CGRect] = [:]
    @State private var cardFrames: [String: CGRect] = [:]
    private static let accountListSpace = "accountListSpace"

    /// Drives the fade of the collapsed Output status line. The full log in the
    /// expanded panel is unaffected — only this one-line summary fades out.
    @State private var statusLineVisible = false
    @State private var statusFadeTask: Task<Void, Never>?
    /// Seconds the status line stays before fading. Errors/warnings never fade.
    private static let statusFadeDelay: Duration = .seconds(4)
    /// Identity of the invisible tail view the Output log auto-scrolls to.
    private static let logBottomAnchor = "logBottom"

    /// Persisted appearance choice: "system" | "light" | "dark".
    @AppStorage("appearancePreference") private var appearancePreference: String = "system"

    /// Output pane starts collapsed to save vertical space; choice is remembered.
    @AppStorage("outputExpanded") private var outputExpanded: Bool = false

    /// GitHub repo-list auto-refresh interval, in seconds. 0 disables it.
    @AppStorage("repoAutoRefreshSeconds") private var repoAutoRefreshSeconds: Int = 300

    /// Account card SSH/gh readiness loading mode.
    @AppStorage("accountStatusLoadMode") private var accountStatusLoadModeRaw: String = AccountStatusLoadMode.smart.rawValue

    /// Preferred GUI editor for the "Open in Editor" button, plus the custom app
    /// name used when the choice is `.custom`.
    @AppStorage("preferredEditor") private var preferredEditorRaw: String = PreferredEditor.none.rawValue
    @AppStorage("customEditorAppName") private var customEditorName: String = ""

    /// Preferred GUI terminal for the cloned-repo Open menu, plus the custom app
    /// name used when the choice is `.custom`.
    @AppStorage("preferredTerminal") private var preferredTerminalRaw: String = PreferredTerminal.none.rawValue
    @AppStorage("customTerminalAppName") private var customTerminalName: String = ""

    // Shared column widths so the header and rows line up.
    private let visWidth: CGFloat = 52
    private let updatedWidth: CGFloat = 150
    // Fits the Open menu plus pull/commit/push/delete icon actions.
    private let actionsWidth: CGFloat = 178

    private var preferredEditor: PreferredEditor {
        PreferredEditor(rawValue: preferredEditorRaw) ?? .none
    }

    private var preferredTerminal: PreferredTerminal {
        PreferredTerminal(rawValue: preferredTerminalRaw) ?? .none
    }

    /// Fixed width for both profile-card auth pills so they read as a matched pair.
    /// Sized to the longest label ("GitHub") plus its status icon.
    private let authBadgeWidth: CGFloat = 78
    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Beta \((version?.isEmpty == false) ? version! : "0.0.1")"
    }

    private enum AccountSummaryStatus {
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
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Locale-aware date+time display. The pattern (field order, separators,
    /// 12/24-hour clock) is derived from the machine's current locale, and the
    /// value is shown in the local time zone.
    private static let updatedDisplayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("yMd jm")
        return f
    }()

    private func formattedUpdated(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        guard let date = Self.isoParser.date(from: raw) else {
            return String(raw.prefix(10))
        }
        return Self.updatedDisplayFormatter.string(from: date)
    }

    private var filteredAccounts: [Account] {
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
        .tint(Theme.purpleAccent)
        .preferredColorScheme(resolvedScheme)
        .coordinateSpace(name: TooltipController.space)
        .overlay { TooltipOverlay() }
        .environmentObject(tooltip)
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
    private var pullAlertTitle: String {
        guard let name = model.pullWarning?.repoName, !name.isEmpty else {
            return "Pull couldn't complete"
        }
        return "Pull couldn't complete — \(name)"
    }

    // MARK: Appearance

    private var resolvedScheme: ColorScheme? {
        switch appearancePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil          // follow system
        }
    }

    private var appearanceIcon: String {
        switch appearancePreference {
        case "light": return "sun.max.fill"
        case "dark": return "moon.fill"
        default: return "circle.lefthalf.filled"
        }
    }

    private var appearanceMenu: some View {
        Menu {
            Picker("Appearance", selection: $appearancePreference) {
                Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                Label("Light", systemImage: "sun.max").tag("light")
                Label("Dark", systemImage: "moon").tag("dark")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: appearanceIcon).foregroundStyle(Theme.purpleAccent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)   // don't take the window's initial keyboard focus (kills the focus ring)
        .tooltip("Appearance: \(appearancePreference.capitalized) — click to change")
    }

    // MARK: Settings (gear → popover)

    private var settingsButton: some View {
        Button { showSettings.toggle() } label: {
            Image(systemName: "gearshape").font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .foregroundStyle(Theme.purpleAccent)
        .tooltip("Settings — account status, repo auto-refresh, and open actions")
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            settingsPopover
        }
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(Theme.title(15))
                .foregroundStyle(Theme.textPrimary)

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
    private func settingsSection<Content: View>(title: String,
                                                help: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            content()
            Text(help)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountStatusLoadMode: AccountStatusLoadMode {
        AccountStatusLoadMode(rawValue: accountStatusLoadModeRaw) ?? .smart
    }

    /// Brand selection background (replaces the system blue highlight).
    @ViewBuilder
    private func selectionBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .fill(selected ? Theme.purpleSubtle : Color.clear)
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.purpleAccent)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            }
    }

    // MARK: Sidebar — accounts (custom selection, no system blue)

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitNest")
                        .font(Theme.title(16))
                        .foregroundStyle(Theme.textPrimary)
                    Text(appVersionLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 8)

                HStack(spacing: 10) {
                    Text("ACCOUNTS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textSecondary).tracking(0.6)
                    Spacer()
                    Button { model.beginAddAccount() } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .foregroundStyle(Theme.purpleAccent)
                    .tooltip("Add a GitHub account")
                    appearanceMenu
                    settingsButton
                }
                .padding(.horizontal, 8).padding(.top, 4)

                if !model.accounts.isEmpty {
                    accountSearchBar
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }

                ForEach(filteredAccounts) { account in
                    accountCard(account)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: AccountCardFramesKey.self,
                                    value: [account.alias: geo.frame(in: .named(Self.accountListSpace))]
                                )
                            }
                        )
                        .scaleEffect(draggingAlias == account.alias ? 1.02 : 1)
                        .shadow(color: .black.opacity(draggingAlias == account.alias ? 0.18 : 0),
                                radius: 9, y: 5)
                        .offset(y: dragOffset(for: account))
                        .zIndex(draggingAlias == account.alias ? 1 : 0)
                        .animation(.interactiveSpring(response: 0.26, dampingFraction: 0.86),
                                   value: dragTargetIndex)
                        .animation(.easeOut(duration: 0.16), value: draggingAlias)
                }
                .onPreferenceChange(AccountCardFramesKey.self) { cardFrames = $0 }
                .animation(.interactiveSpring(response: 0.24,
                                              dampingFraction: 0.86,
                                              blendDuration: 0.08),
                           value: model.accounts.map(\.alias))

                if filteredAccounts.isEmpty && !accountSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No accounts match.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                }
            }
            .padding(10)
            .coordinateSpace(name: Self.accountListSpace)
        }
        .frame(minWidth: 280)
        .background(Theme.surface)
        .safeAreaInset(edge: .bottom) {
            Button { model.refreshAll(statusMode: accountStatusLoadMode, manual: true) } label: {
                Label("Refresh", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(SubtleButtonStyle())
            .tooltip("Reload accounts and run SSH/gh checks using the selected account-status mode")
            .padding(10)
        }
        .confirmationDialog(
            "Run gh auth login?",
            isPresented: Binding(
                get: { ghLoginTarget != nil },
                set: { if !$0 { ghLoginTarget = nil } }
            ),
            presenting: ghLoginTarget
        ) { account in
            Button("Continue and open login page") {
                let target = account
                ghLoginTarget = nil
                Task { await model.reauthenticateGh(for: target) }
            }
            Button("Cancel", role: .cancel) {
                ghLoginTarget = nil
            }
        } message: { account in
            Text("""
            This runs `gh auth login --web` and opens GitHub device login in your browser.
            The one-time code is copied to your clipboard automatically.
            Sign in as \(account.alias) if that is the account you want to refresh.
            """)
        }
        .sheet(isPresented: $model.addAccountActive) {
            AddAccountSheet().environmentObject(model)
        }
    }

    private var accountSearchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField("Wild search accounts…", text: $accountSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !accountSearch.isEmpty {
                Text("\(filteredAccounts.count)/\(model.accounts.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Button { accountSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .tooltip("Clear account search")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Theme.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1))
    }

    private func accountCard(_ account: Account) -> some View {
        let showsReorderControls = accountSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.accounts.count > 1
        return accountRow(account, showsReorderControls: showsReorderControls)
            .background(selectionBackground(model.selectedAccount == account))
            .contentShape(Rectangle())
            .onTapGesture {
                model.selectAccount(account)
            }
    }

    private func accountRow(_ account: Account, showsReorderControls: Bool) -> some View {
        let expanded = expandedAccountAliases.contains(account.alias)
        return HStack(alignment: expanded ? .top : .center, spacing: 9) {
            if showsReorderControls {
                accountReorderControls(account)
            }
            avatar(for: account, size: expanded ? 40 : 32)
            VStack(alignment: .leading, spacing: expanded ? 3 : 0) {
                HStack(spacing: 5) {
                    Text(account.name)
                        .font(Theme.title(expanded ? 15 : 14))
                        .lineLimit(1)
                    accountSummaryIndicator(account)
                    Button {
                        toggleAccountDetails(account)
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .tooltip(expanded ? "Hide account details" : "Show account details")
                }

                if expanded {
                    Text(account.email).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Text(account.sshHost).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                    if let greeting = model.sshGreetings[account.alias] {
                        let ok = model.accountSSHReady(account)
                        authBadge(
                            ok: ok,
                            label: "SSH",
                            status: ok ? "Git SSH ready" : sshStatusText(account: account, greeting: greeting),
                            help: "SSH key/auth check via ssh -T git@\(account.sshHost)"
                        )
                    }
                    if let gh = model.ghIndicators[account.alias] {
                        authBadge(
                            ok: gh.ok,
                            label: "GitHub",
                            status: gh.ok ? "GitHub ready" : "GitHub login required",
                            help: "GitHub CLI session check via gh auth switch/status"
                        )
                    }

                    // Per-account actions live in the expanded detail so collapsed
                    // cards stay compact.
                    HStack(spacing: 7) {
                        ActionIconButton(systemName: "person.badge.key",
                                         help: "Run gh auth login (web) for this account",
                                         tint: Theme.purpleAccent,
                                         fill: Theme.purpleSubtle) {
                            ghLoginTarget = account
                        }
                        ActionIconButton(systemName: "globe",
                                         help: "Open github.com/\(account.alias) in your browser",
                                         tint: Theme.purpleAccent,
                                         fill: Theme.purpleSubtle) {
                            model.openGitHubProfile(account)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, expanded ? 7 : 5)
        .padding(.horizontal, 8)
        .animation(.easeInOut(duration: 0.16), value: expanded)
    }

    private func toggleAccountDetails(_ account: Account) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if expandedAccountAliases.contains(account.alias) {
                expandedAccountAliases.remove(account.alias)
            } else {
                expandedAccountAliases.insert(account.alias)
            }
        }
    }

    @ViewBuilder
    private func accountSummaryIndicator(_ account: Account) -> some View {
        let status = accountSummaryStatus(account)
        switch status {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.46)
                .frame(width: 14, height: 14)
                .tooltip(status.help)
                .accessibilityLabel(status.help)
        case .notLoaded:
            accountSummaryImage(systemName: "circle.dashed",
                                tint: Theme.textTertiary,
                                help: status.help)
        case .ready:
            accountSummaryImage(systemName: "checkmark.circle.fill",
                                tint: Theme.green,
                                help: status.help)
        case .partial:
            accountSummaryImage(systemName: "questionmark.circle.fill",
                                tint: Theme.amber,
                                help: status.help)
        case .failed:
            accountSummaryImage(systemName: "xmark.circle.fill",
                                tint: Theme.danger,
                                help: status.help)
        }
    }

    private func accountSummaryImage(systemName: String, tint: Color, help: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 14, height: 14)
            .tooltip(help)
            .accessibilityLabel(help)
    }

    private func accountSummaryStatus(_ account: Account) -> AccountSummaryStatus {
        if model.accountChecking(account) {
            return .loading
        }
        guard model.accountStatusKnown(account) else {
            return .notLoaded
        }
        let sshReady = model.accountSSHReady(account)
        let ghReady = model.accountGhReady(account)
        if sshReady && ghReady {
            return .ready
        }
        if !sshReady && !ghReady {
            return .failed
        }
        return .partial
    }

    /// Drag handle — grab it and drag to reorder the account. Only this rail starts
    /// a reorder, so dragging anywhere else on the card still scrolls the list.
    private func accountReorderControls(_ account: Account) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(draggingAlias == account.alias ? Theme.purpleAccent : Theme.textTertiary)
            .frame(width: 22, height: 40, alignment: .center)
            .contentShape(Rectangle())
            .simultaneousGesture(reorderDragGesture(account))
            .tooltip("Drag to reorder")
            .accessibilityLabel("Drag to reorder \(account.alias)")
    }

    // MARK: Drag-to-reorder

    private func reorderDragGesture(_ account: Account) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.accountListSpace))
            .onChanged { value in
                if draggingAlias == nil {
                    draggingAlias = account.alias
                    dragStartOrder = model.accounts.map(\.alias)
                    dragStartFrames = cardFrames
                    dragStartMidY = cardFrames[account.alias]?.midY ?? value.location.y
                    dragTargetIndex = dragStartOrder.firstIndex(of: account.alias)
                }
                dragTranslation = value.translation.height
                updateDragTarget()
            }
            .onEnded { _ in endDragReorder() }
    }

    /// Where a card sits relative to its model slot while a drag is in progress.
    /// The dragged card tracks the finger directly; the others shift by the dragged
    /// card's height to open a gap at the drop slot. Everything is 0 when idle.
    private func dragOffset(for account: Account) -> CGFloat {
        guard let alias = draggingAlias else { return 0 }
        if account.alias == alias { return dragTranslation }
        guard let target = dragTargetIndex,
              let origIndex = dragStartOrder.firstIndex(of: alias),
              let j = dragStartOrder.firstIndex(of: account.alias),
              let dragged = dragStartFrames[alias] else { return 0 }
        let pitch = dragged.height + 4   // card height + the VStack's 4pt spacing
        if origIndex < target, j > origIndex, j <= target { return -pitch }   // dragged moving down
        if origIndex > target, j >= target, j < origIndex { return pitch }    // dragged moving up
        return 0
    }

    /// Pick the drop slot from the finger's projected center against the cards'
    /// original positions: the target index is how many *other* cards start above
    /// the finger. Robust to variable card heights and computed fresh each move.
    private func updateDragTarget() {
        guard let alias = draggingAlias else { return }
        let projectedCenter = dragStartMidY + dragTranslation
        let target = dragStartOrder
            .filter { $0 != alias }
            .filter { (dragStartFrames[$0]?.midY ?? .greatestFiniteMagnitude) < projectedCenter }
            .count
        if dragTargetIndex != target { dragTargetIndex = target }
    }

    private func endDragReorder() {
        guard let alias = draggingAlias, let target = dragTargetIndex else {
            resetDragState()
            return
        }
        withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.82)) {
            model.moveAccount(alias: alias, toIndex: target)
            resetDragState()
        }
    }

    private func resetDragState() {
        draggingAlias = nil
        dragTranslation = 0
        dragStartMidY = 0
        dragTargetIndex = nil
        dragStartOrder = []
        dragStartFrames = [:]
    }

    /// Compact status pill: a ✓/✗ icon plus a short label (SSH / GitHub). Both
    /// pills share `authBadgeWidth` so they read as a matched pair; the full
    /// status (and the underlying check) live in the tooltip.
    private func authBadge(ok: Bool, label: String, status: String, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ok ? Theme.green : Theme.danger)
        .padding(.vertical, 2).padding(.horizontal, 7)
        // Fix the width before the background so the colored pill itself is the
        // same size for both indicators (not just the layout slot).
        .frame(width: authBadgeWidth, alignment: .leading)
        .background(ok ? Theme.greenSubtle : Theme.dangerSubtle)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMicro, style: .continuous))
        .tooltip("\(status) — \(help)")
    }

    private func sshStatusText(account: Account, greeting: String) -> String {
        if let login = AccountSetup.sshLogin(from: greeting) {
            return "SSH authenticated as \(login), expected \(account.alias)"
        }
        return greeting
    }

    // GitHub serves each user's avatar at https://github.com/<login>.png .
    private func avatar(for account: Account, size: CGFloat = 40) -> some View {
        AsyncImage(url: URL(string: "https://github.com/\(account.alias).png?size=80")) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1))
    }

    // MARK: Detail — repos + actions

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let account = model.selectedAccount {
                header(account)
                Divider().overlay(Theme.border)
                if !model.isLoadingRepos && !model.repos.isEmpty {
                    repoSearchBar
                }
                repoList(account)
                cloneBar
            } else {
                Spacer()
                Text("Select an account on the left.")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            Divider().overlay(Theme.border)
            outputPane
        }
        .padding(18)
        .background(Theme.surface)
    }

    private func header(_ account: Account) -> some View {
        let ready = model.accountReady(account)
        let gateHint = connectionGateHint(account)
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name).font(Theme.display(22))
                Label(account.folder, systemImage: "folder")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            HStack(spacing: 10) {
                Button {
                    chooseInitFolder(for: account)
                } label: {
                    Label("Init project", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryPurpleButtonStyle())
                .tooltip(gateHint ?? "Choose a local project folder, create a GitHub repo, and push it")
                .disabled(!ready || model.isInitializingProject || model.isLoadingRepos || model.isForkingProject)

                Button {
                    showForkSheet = true
                    forkAddress = ""
                } label: {
                    Label("Fork project", systemImage: "tuningfork")
                }
                .buttonStyle(PrimaryPurpleButtonStyle())
                .tooltip(gateHint ?? "Fork a GitHub repository into this account and clone it")
                .disabled(!ready || model.isInitializingProject || model.isLoadingRepos || model.isForkingProject)

                Button {
                    Task { await model.loadRepos(for: account) }
                } label: {
                    Label("Load repos", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(PrimaryPurpleButtonStyle())
                .tooltip(gateHint ?? "List every repo \(account.alias) owns (via gh)")
                .disabled(!ready || model.isLoadingRepos || model.isInitializingProject || model.isForkingProject)
            }
        }
    }

    /// Why the action buttons are greyed out (nil once the account is ready) —
    /// surfaced as the buttons' tooltip so the disabled state isn't a mystery.
    private func connectionGateHint(_ account: Account) -> String? {
        if model.accountReady(account) { return nil }
        if model.accountChecking(account) {
            return "Checking SSH and GitHub connection for \(account.alias)…"
        }
        if !model.accountStatusKnown(account) {
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
        Task { initPlan = await model.makeInitPlan(sourceURL: url, account: account) }
    }

    private func startProjectInit(_ plan: ProjectInitPlan,
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

    private func initProjectSheet(_ plan: ProjectInitPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Initialize Project")
                    .font(Theme.title(18))
                Text("\(plan.account.alias)/\(plan.repoName)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }

            Divider().overlay(Theme.border)

            VStack(alignment: .leading, spacing: 10) {
                Label(plan.sourcePath, systemImage: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                if plan.willCopy {
                    Label("Will copy to \(plan.workingPath)", systemImage: "arrow.turn.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("Use the copied folder for future development after upload.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    if let origin = plan.sourceOrigin {
                        Label("This folder is a clone of \(origin) — its full commit history will be pushed to \(plan.account.alias)/\(plan.repoName).",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label("Already inside \(plan.account.alias)'s GitHub folder; will initialize in place.",
                          systemImage: "checkmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.green)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Repo type")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                Picker("Repo type", selection: $initVisibility) {
                    ForEach(RepoVisibilityChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if plan.willCopy {
                Toggle("Move original selected folder to Trash after upload", isOn: $moveOriginalToTrash)
                    .font(.system(size: 12, weight: .medium))
                Text("The copied folder in \(plan.account.alias)'s GitHub folder will remain.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Label("Trash cleanup is unavailable because this folder is already in the account folder.",
                      systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
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
                .buttonStyle(PrimaryPurpleButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.surface)
    }

    private var forkProjectSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Fork Project")
                    .font(Theme.title(18))
                Text("Enter the GitHub repository address to fork into \(model.selectedAccount?.alias ?? "this account").")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }

            Divider().overlay(Theme.border)

            VStack(alignment: .leading, spacing: 8) {
                Text("GitHub project address")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                TextField("e.g. https://github.com/owner/repo or owner/repo", text: $forkAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(model.isForkingProject)
                Text("The repository will be forked to your account, then cloned into the account folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isForkingProject {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Forking and cloning…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
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
                .buttonStyle(PrimaryPurpleButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.isForkingProject || RepoReference.parse(forkAddress) == nil)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.surface)
    }

    // MARK: Repo list (custom selection, no system blue)

    @ViewBuilder
    private func repoList(_ account: Account) -> some View {
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
                Divider().overlay(Theme.border)
                ScrollView {
                    if model.filteredRepos.isEmpty {
                        repoListEmptyState
                    } else {
                        LazyVStack(spacing: 2) {
                            ForEach(model.filteredRepos) { repo in repoRow(repo) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(minHeight: 240)
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .sheet(item: $commitTarget) { repo in commitSheet(repo) }
            .confirmationDialog(
                "Push this repository to GitHub?",
                isPresented: Binding(get: { pushTarget != nil },
                                     set: { if !$0 { pushTarget = nil } }),
                presenting: pushTarget
            ) { repo in
                Button("Push to GitHub") {
                    let target = repo
                    pushTarget = nil
                    Task { await model.push(target) }
                }
                Button("Cancel", role: .cancel) {
                    pushTarget = nil
                }
            } message: { repo in
                Text("This will run git push for “\(repo.name)”. Make sure the local commits and branch are ready to publish.")
            }
            .confirmationDialog(
                "Move this folder to Trash?",
                isPresented: Binding(get: { deleteTarget != nil },
                                     set: { if !$0 { deleteTarget = nil } }),
                presenting: deleteTarget
            ) { repo in
                Button("Move to Trash", role: .destructive) {
                    let target = repo; deleteTarget = nil
                    Task { await model.deleteLocalFolder(target) }
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: { repo in
                Text("“\(repo.name)” will be moved to the Trash (recoverable). The GitHub repository is NOT affected.")
            }
        }
    }

    private var repoSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField("Wild search repos…  (part of a name, glob like m*ger, or fuzzy “mgm”)",
                      text: $model.repoSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !model.repoSearch.isEmpty {
                Text("\(model.filteredRepos.count)/\(model.repos.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Button { model.repoSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .tooltip("Clear search")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1))
    }

    @ViewBuilder
    private var repoListEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.repos.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(Theme.textTertiary)
            Text(model.repos.isEmpty
                 ? "No repositories loaded yet."
                 : "No repositories match “\(model.repoSearch)”.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            if !model.repos.isEmpty {
                Button("Clear search") { model.repoSearch = "" }
                    .buttonStyle(SubtleButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private var repoListHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 18, height: 18)
            sortHeader("Repository", field: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: visWidth, height: 1)   // visibility column (icon-only, no title)
            sortHeader("Updated", field: .updated)
                .frame(width: updatedWidth, alignment: .leading)
            Text("Actions").frame(width: actionsWidth, alignment: .trailing)
        }
        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(height: 28)
    }

    /// A clickable column title: click toggles ASC/DESC, click another column to
    /// switch. An arrow shows the active column and direction.
    private func sortHeader(_ title: String, field: RepoSortField) -> some View {
        let active = model.repoSortField == field
        return Button {
            model.sortBy(field)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: active ? (model.repoSortAscending ? "chevron.up" : "chevron.down")
                                         : "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(active ? Theme.purpleAccent : Theme.textSecondary.opacity(0.45))
            }
            .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func repoRow(_ repo: Repo) -> some View {
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
                    if let status { statusBadges(status, repo: repo) }
                }
                if let d = repo.description, !d.isEmpty {
                    Text(d).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            visBadge(repo.visibility)
                .frame(width: visWidth, alignment: .center)
            Text(formattedUpdated(repo.updatedAt))
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: updatedWidth, alignment: .leading)
            rowActions(repo).frame(width: actionsWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(selectionBackground(selected))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border.opacity(0.75))
                .frame(height: 1)
                .padding(.leading, 30) // keep icon gutter visually clean
                .padding(.trailing, 12)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedRepo = repo.id }
        .padding(.horizontal, 4)
    }

    private func repoIcon(cloned: Bool, conflict: AppModel.RepoFolderConflict?) -> String {
        if cloned { return "internaldrive.fill" }
        if conflict != nil { return "exclamationmark.triangle.fill" }
        return "cloud"
    }

    private func repoIconColor(cloned: Bool,
                               attention: Bool,
                               conflict: AppModel.RepoFolderConflict?) -> Color {
        if conflict != nil { return Theme.amber }
        if cloned { return attention ? Theme.amber : Theme.purpleAccent }
        return Theme.textSecondary
    }

    /// A repo is "shared" when its owner is not the selected account — i.e. you
    /// were added as a collaborator. Own repos return false (no badge).
    private func isShared(_ repo: Repo) -> Bool {
        guard let me = model.selectedAccount?.alias else { return false }
        return repo.owner.caseInsensitiveCompare(me) != .orderedSame
    }

    /// Grey two-people icon marking a repo shared with you by another account.
    /// The owner login lives in the tooltip to keep the row uncluttered.
    private func sharedBadge(_ owner: String) -> some View {
        Image(systemName: "person.2.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .tooltip("Shared by \(owner) — you're a collaborator")
            .accessibilityLabel("Shared by \(owner)")
    }

    private func folderConflictBadge(_ conflict: AppModel.RepoFolderConflict) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.amber)
            .tooltip(conflict.shortHelp)
            .accessibilityLabel(conflict.shortHelp)
    }

    /// Visibility as a glanceable icon: amber lock = private, green globe =
    /// public, grey building = internal. The word stays in the tooltip.
    @ViewBuilder
    private func visBadge(_ raw: String) -> some View {
        switch raw.lowercased() {
        case "private":
            visIcon("lock.fill", Theme.amber, "Private")
        case "public":
            visIcon("globe", Theme.green, "Public")
        case "internal":
            visIcon("building.2.fill", Theme.textSecondary, "Internal")
        default:
            Text(raw.lowercased())
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func visIcon(_ name: String, _ color: Color, _ label: String) -> some View {
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
    private func statusBadges(_ status: RepoStatus, repo: Repo) -> some View {
        HStack(spacing: 4) {
            if status.isDiverged {
                statusIconPill("exclamationmark.triangle.fill", Theme.amber, Theme.amberSubtle,
                               help: "Local and remote both have commits. Pull or rebase before pushing.")
            }
            if status.changedFiles > 0 {
                ChangeSummaryButton(repo: repo, count: status.changedFiles)
            }
            if status.ahead > 0 {
                statusPill("arrow.up", status.ahead, Theme.purpleAccent, Theme.purpleSubtle,
                           help: "\(plural(status.ahead, "local commit")) not pushed yet")
            }
            if status.behind > 0 {
                statusPill("arrow.down", status.behind, Theme.amber, Theme.amberSubtle,
                           help: "\(plural(status.behind, "commit")) behind upstream remote\(remoteCheckContext(status))")
            }
            remoteStateBadge(status)
        }
    }

    private func statusPill(_ icon: String, _ count: Int, _ tint: Color, _ fill: Color, help: String) -> some View {
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

    private func statusIconPill(_ icon: String, _ tint: Color, _ fill: Color, help: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(.vertical, 2).padding(.horizontal, 5)
            .background(fill)
            .clipShape(Capsule())
            .tooltip(help)
    }

    @ViewBuilder
    private func remoteStateBadge(_ status: RepoStatus) -> some View {
        switch status.remoteState {
        case .checked where status.isCleanAndCurrent:
            statusIconPill("checkmark", Theme.green, Theme.greenSubtle,
                           help: "Up to date with upstream remote (checked with git fetch)")
        case .failed(let message):
            statusIconPill("exclamationmark.triangle.fill", Theme.danger, Theme.dangerSubtle,
                           help: "Remote check failed: \(message)")
        case .noUpstream:
            statusIconPill("questionmark.circle.fill", Theme.textSecondary, Theme.surfaceMuted,
                           help: "No upstream branch configured; cannot compare this clone with GitHub")
        case .upstreamGone:
            statusIconPill("exclamationmark.triangle.fill", Theme.amber, Theme.amberSubtle,
                           help: "The upstream branch no longer exists on the remote (deleted or renamed). Push the branch again or re-set its upstream.")
        case .checked, .unchecked:
            EmptyView()
        }
    }

    private func remoteCheckContext(_ status: RepoStatus) -> String {
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

    private func cloneIconHelp(cloned: Bool,
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

    private func plural(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private func openMenu(_ repo: Repo) -> some View {
        ActionPopoverButton(systemName: "folder", help: "Open…") { isPresented in
            VStack(alignment: .leading, spacing: 4) {
                openPopoverButton("Finder", systemImage: "folder") {
                    isPresented.wrappedValue = false
                    model.openLocalFolder(repo)
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
                        Task { await model.openInEditor(repo, editor: preferredEditor, customAppName: customEditorName) }
                    }
                }

                if preferredTerminal == .none {
                    openPopoverDisabledRow("Terminal not configured", systemImage: "terminal")
                } else {
                    openPopoverButton(preferredTerminal.displayName(customAppName: customTerminalName),
                                      systemImage: "terminal") {
                        isPresented.wrappedValue = false
                        Task { await model.openInTerminal(repo, terminal: preferredTerminal, customAppName: customTerminalName) }
                    }
                }
            }
            .padding(8)
            .frame(width: 220)
            .background(Theme.surface)
        }
    }

    private func openPopoverButton(_ title: String,
                                   systemImage: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.surfaceMuted.opacity(0.001))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }

    private func openPopoverDisabledRow(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .opacity(0.75)
    }

    @ViewBuilder
    private func rowActions(_ repo: Repo) -> some View {
        HStack(spacing: 7) {
            if model.isCloned(repo) {
                openMenu(repo)
                iconButton("arrow.down", "Pull (git pull)") { Task { await model.pull(repo) } }
                iconButton("pencil", "Commit all changes…") { commitMessage = ""; commitTarget = repo }
                iconButton("arrow.up", "Push (git push)") { pushTarget = repo }
                iconButton("trash", "Move local folder to Trash (recoverable)",
                           tint: Theme.danger, fill: Theme.dangerSubtle) { deleteTarget = repo }
            } else if let conflict = model.folderConflict(repo) {
                disabledIconChip("exclamationmark.triangle.fill",
                                 conflict.shortHelp,
                                 tint: Theme.amber,
                                 fill: Theme.amberSubtle)
            } else {
                iconButton("square.and.arrow.down", "Clone into the account folder") {
                    Task { await model.clone(repo) }
                }
            }
        }
        // A pull/push/commit/clone is already running for this repo — block a second
        // one rather than let two git processes collide on `index.lock`.
        .disabled(model.busyRepos.contains(repo.id))
    }

    private func iconButton(_ systemName: String, _ help: String,
                            tint: Color = Theme.purpleAccent, fill: Color = Theme.purpleSubtle,
                            _ action: @escaping () -> Void) -> some View {
        ActionIconButton(systemName: systemName, help: help, tint: tint, fill: fill, action: action)
    }

    private func disabledIconChip(_ systemName: String,
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

    private func commitSheet(_ repo: Repo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Commit all changes in \(repo.name)").font(Theme.title(16))
            Text("Runs:  git add -A  &&  git commit -m …")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            TextField("Commit message", text: $commitMessage)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
            HStack {
                Spacer()
                Button("Cancel") { commitTarget = nil }
                    .buttonStyle(SubtleButtonStyle())
                Button("Commit") {
                    let message = commitMessage
                    let target = repo
                    commitTarget = nil
                    Task { await model.commit(target, message: message) }
                }
                .buttonStyle(PrimaryPurpleButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .background(Theme.surface)
    }

    private var cloneBar: some View {
        HStack(spacing: 16) {
            Label("Remote only", systemImage: "cloud").foregroundStyle(Theme.textSecondary)
            Label("Cloned locally", systemImage: "internaldrive.fill").foregroundStyle(Theme.purpleAccent)
            Spacer()
            repoRefreshStatus
            Text(model.repoSearch.isEmpty
                 ? "\(model.repos.count) repo(s)"
                 : "\(model.filteredRepos.count) of \(model.repos.count) repo(s)")
                .foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: 11, weight: .medium))
    }

    @ViewBuilder
    private var repoRefreshStatus: some View {
        if model.isLoadingRepos || model.isRefreshingRepos {
            Label("Refreshing repos…", systemImage: "arrow.clockwise")
                .foregroundStyle(Theme.amber)
                .lineLimit(1)
                .tooltip("Refreshing GitHub repo list")
        } else if model.isCheckingRepoRemotes {
            Label("Checking cloned remotes…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(Theme.amber)
                .lineLimit(1)
                .tooltip("Fetching upstream remotes for cloned repos")
        } else if let message = model.repoRefreshMessage, !message.isEmpty {
            let failed = message.localizedCaseInsensitiveContains("failed")
            Label(message, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failed ? Theme.danger : Theme.green)
                .lineLimit(1)
                .tooltip(message)
        }
    }

    private var lastLogLine: String? {
        model.log
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init)
    }

    private var outputPane: some View {
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
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !outputExpanded, let last = lastLogLine {
                    Text(last)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
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
                        .foregroundStyle(Theme.purpleAccent)
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
                    .background(Theme.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1))
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
    private func refreshStatusLine() {
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

/// Collects each account card's frame (in the account-list coordinate space) so
/// drag-to-reorder can map the finger position to a drop slot.
private struct AccountCardFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct ActionIconButton: View {
    let systemName: String
    let help: String
    let tint: Color
    let fill: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(IconChipButtonStyle(tint: tint, fill: fill, isHovered: isHovering))
        .tooltip(help)
        .accessibilityLabel(help)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct ActionPopoverButton<PopoverContent: View>: View {
    let systemName: String
    let help: String
    var tint: Color = Theme.purpleAccent
    var fill: Color = Theme.purpleSubtle
    private let content: (Binding<Bool>) -> PopoverContent

    @State private var isHovering = false
    @State private var isPresented = false

    init(systemName: String,
         help: String,
         tint: Color = Theme.purpleAccent,
         fill: Color = Theme.purpleSubtle,
         @ViewBuilder content: @escaping (Binding<Bool>) -> PopoverContent) {
        self.systemName = systemName
        self.help = help
        self.tint = tint
        self.fill = fill
        self.content = content
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: systemName)
        }
        .buttonStyle(IconChipButtonStyle(tint: tint, fill: fill, isHovered: isHovering || isPresented))
        .tooltip(help)
        .accessibilityLabel(help)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content($isPresented)
                .onDisappear {
                    if isPresented { isPresented = false }
                }
        }
    }
}
