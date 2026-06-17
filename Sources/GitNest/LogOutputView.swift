import SwiftUI

struct LogOutputView: View {
    @EnvironmentObject var logStore: LogStore
    @EnvironmentObject var accountManager: AccountManager
    @Binding var outputExpanded: Bool
    @Environment(\.theme) private var theme

    /// Drives the fade of the collapsed Output status line. The full log in the
    /// expanded panel is unaffected — only this one-line summary fades out.
    @State var statusLineVisible = false
    @State var statusFadeTask: Task<Void, Never>?
    /// Seconds the status line stays before fading. Errors/warnings never fade.
    static let statusFadeDelay: Duration = .seconds(4)
    /// Identity of the invisible tail view the Output log auto-scrolls to.
    static let logBottomAnchor = "logBottom"

    var lastLogLine: String? {
        logStore.log
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init)
    }

    var body: some View {
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
                    Task { await accountManager.logAuthStatus() }
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
                        Text(logStore.log.isEmpty ? "—" : logStore.log)
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
                    .onChange(of: logStore.log) { _ in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.logBottomAnchor, anchor: .bottom) }
                    }
                    .onAppear { proxy.scrollTo(Self.logBottomAnchor, anchor: .bottom) }
                }
            }
        }
        // Every new log line refreshes the collapsed status: show it, then fade
        // after a delay — unless it's an error/warning, which stays pinned.
        .onChange(of: logStore.log) { _ in refreshStatusLine() }
    }

    /// Shows the collapsed Output status line and schedules it to fade out, so a
    /// finished "Opening…"/"Cloning…" message doesn't linger and look in-progress.
    /// Failures/warnings are left pinned until the next action replaces them.
    func refreshStatusLine() {
        statusFadeTask?.cancel()
        statusLineVisible = true
        guard !logStore.lastWasError else { statusFadeTask = nil; return }
        statusFadeTask = Task { @MainActor in
            try? await Task.sleep(for: Self.statusFadeDelay)
            guard !Task.isCancelled else { return }
            statusLineVisible = false
        }
    }
}
