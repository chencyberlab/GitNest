import SwiftUI

/// Settings popover content: appearance, colour scheme, repo auto-refresh,
/// preferred editor and terminal.
struct SettingsPopoverView: View {
    @Binding var showSettings: Bool
    @Binding var appearancePreference: String
    @Binding var colorThemeID: String
    @Binding var windowTransparencyEnabled: Bool
    @Binding var windowTransparencyPercent: Int
    @Binding var repoAutoRefreshSeconds: Int
    @Binding var accountStatusLoadModeRaw: String
    @Binding var preferredEditorRaw: String
    @Binding var customEditorName: String
    @Binding var preferredTerminalRaw: String
    @Binding var customTerminalName: String
    @Environment(\.theme) private var theme

    /// Cursor-over feedback for the close button — a faint circular wash matches
    /// the chip-style buttons used elsewhere, so it reads as tappable at a glance.
    @State private var closeHovering = false

    private var accountStatusLoadMode: AccountStatusLoadMode {
        AccountStatusLoadMode(rawValue: accountStatusLoadModeRaw) ?? .smart
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings")
                    .font(Theme.title(15))
                    .foregroundStyle(theme.text)
                Spacer()
                Button { showSettings = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(closeHovering ? theme.text : theme.textTertiary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(closeHovering ? theme.surfaceMuted : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close settings")
                .onHover { closeHovering = $0 }
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
                title: "Window transparency",
                help: "Frosted glass over the desktop. The slider sets one global amount for the whole window (0% = solid look, 100% = maximum glass). Turn the switch off for fully opaque chrome."
            ) {
                Toggle("Transparent window", isOn: $windowTransparencyEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Transparent window")

                if windowTransparencyEnabled {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(WindowTransparencyPreference.clampedPercent(windowTransparencyPercent)) },
                                set: { windowTransparencyPercent = Int($0.rounded()) }
                            ),
                            in: 0...100,
                            step: 5
                        )
                        .accessibilityLabel("Transparency amount")
                        Text("\(WindowTransparencyPreference.clampedPercent(windowTransparencyPercent))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textMuted)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
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

                if PreferredEditor(rawValue: preferredEditorRaw) == .custom {
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

                if PreferredTerminal(rawValue: preferredTerminalRaw) == .custom {
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
                .foregroundStyle(theme.text)
            content()
            Text(help)
                .font(.system(size: 10))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
