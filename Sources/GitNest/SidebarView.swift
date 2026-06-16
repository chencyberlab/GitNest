import SwiftUI

/// Account list sidebar: search, cards, drag-to-reorder, add-account,
/// appearance/settings controls, and refresh.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme

    @Binding var accountSearch: String
    @Binding var expandedAccountAliases: Set<String>
    @Binding var ghLoginTarget: Account?
    @Binding var showSettings: Bool

    @Binding var appearancePreference: String
    @Binding var colorThemeID: String
    @Binding var repoAutoRefreshSeconds: Int
    @Binding var accountStatusLoadModeRaw: String
    @Binding var preferredEditorRaw: String
    @Binding var customEditorName: String
    @Binding var preferredTerminalRaw: String
    @Binding var customTerminalName: String

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

    private var accountStatusLoadMode: AccountStatusLoadMode {
        AccountStatusLoadMode(rawValue: accountStatusLoadModeRaw) ?? .smart
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Beta \(version.nilIfEmpty ?? "1.0.0")"
    }

    private var filteredAccounts: [Account] {
        let query = accountSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.accounts }
        return model.accounts.filter { AccountSearch.matches(query: query, account: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitNest")
                        .font(Theme.title(16))
                        .foregroundStyle(theme.text)
                    Text(appVersionLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 8)

                HStack(spacing: 10) {
                    Text("ACCOUNTS")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.textMuted).tracking(0.6)
                    Spacer()
                    Button { model.beginAddAccount() } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
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
                        .foregroundStyle(theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                }
            }
            .padding(10)
            .coordinateSpace(name: Self.accountListSpace)
        }
        .frame(minWidth: 280)
        .background(theme.surface)
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
        .sheet(isPresented: model.addAccountActiveBinding) {
            AddAccountSheet().environmentObject(model.setupCoordinator)
        }
    }

    // MARK: Search

    private var accountSearchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textMuted)
            TextField("Wild search accounts…", text: $accountSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !accountSearch.isEmpty {
                Text("\(filteredAccounts.count)/\(model.accounts.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Button { accountSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .tooltip("Clear account search")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(theme.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .strokeBorder(theme.border, lineWidth: 1))
    }

    // MARK: Account card

    private func accountCard(_ account: Account) -> some View {
        let showsReorderControls = accountSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.accounts.count > 1
        return accountRow(account, showsReorderControls: showsReorderControls)
            .background(SelectionBackground(selected: model.selectedAccount == account))
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
                            .foregroundStyle(theme.textTertiary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .tooltip(expanded ? "Hide account details" : "Show account details")
                }

                if expanded {
                    Text(account.email).font(.system(size: 11)).foregroundStyle(theme.textMuted)
                    Text(account.sshHost).font(.system(size: 10)).foregroundStyle(theme.textTertiary)
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
                                         tint: theme.accent,
                                         fill: theme.accentSubtle) {
                            ghLoginTarget = account
                        }
                        ActionIconButton(systemName: "globe",
                                         help: "Open github.com/\(account.alias) in your browser",
                                         tint: theme.accent,
                                         fill: theme.accentSubtle) {
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
                                tint: theme.textTertiary,
                                help: status.help)
        case .ready:
            accountSummaryImage(systemName: "checkmark.circle.fill",
                                tint: theme.success,
                                help: status.help)
        case .partial:
            accountSummaryImage(systemName: "questionmark.circle.fill",
                                tint: theme.warning,
                                help: status.help)
        case .failed:
            accountSummaryImage(systemName: "xmark.circle.fill",
                                tint: theme.error,
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

    // MARK: Drag-to-reorder

    /// Drag handle — grab it and drag to reorder the account. Only this rail starts
    /// a reorder, so dragging anywhere else on the card still scrolls the list.
    private func accountReorderControls(_ account: Account) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(draggingAlias == account.alias ? theme.accent : theme.textTertiary)
            .frame(width: 22, height: 40, alignment: .center)
            .contentShape(Rectangle())
            .simultaneousGesture(reorderDragGesture(account))
            .tooltip("Drag to reorder")
            .accessibilityLabel("Drag to reorder \(account.alias)")
    }

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

    // MARK: Appearance and settings

    private var appearanceMenu: some View {
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

    private var appearanceIcon: String {
        switch appearancePreference {
        case "light": return "sun.max.fill"
        case "dark": return "moon.fill"
        default: return "circle.lefthalf.filled"
        }
    }

    private var settingsButton: some View {
        Button { showSettings.toggle() } label: {
            Image(systemName: "gearshape").font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .tooltip("Settings — account status, repo auto-refresh, and open actions")
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            SettingsPopoverView(
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
        }
    }

    // MARK: Auth badges

    /// Compact status pill: a ✓/✗ icon plus a short label (SSH / GitHub). Both
    /// pills share `LayoutMetrics.authBadgeWidth` so they read as a matched pair;
    /// the full status (and the underlying check) live in the tooltip.
    private func authBadge(ok: Bool, label: String, status: String, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ok ? theme.success : theme.error)
        .padding(.vertical, 2).padding(.horizontal, 7)
        // Fix the width before the background so the colored pill itself is the
        // same size for both indicators (not just the layout slot).
        .frame(width: LayoutMetrics.authBadgeWidth, alignment: .leading)
        .background(ok ? theme.successSubtle : theme.errorSubtle)
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
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(theme.textMuted)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(theme.border, lineWidth: 1))
    }
}
