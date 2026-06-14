import SwiftUI

/// A single repository row in the repo list: icon, name, status pills, and actions.
struct RepoRowView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme

    let repo: Repo
    let account: Account

    @Binding var commitTarget: RepoActionTarget?
    @Binding var pushTarget: RepoActionTarget?
    @Binding var deleteTarget: RepoActionTarget?

    let preferredEditor: PreferredEditor
    let preferredTerminal: PreferredTerminal
    let customEditorName: String
    let customTerminalName: String

    var body: some View {
        let selected = model.selectedRepo == repo.id
        let status = model.repoStatuses[repo.id]
        let cloned = model.repoManager.isCloned(repo)
        let conflict = model.repoManager.folderConflict(repo)
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
                .frame(width: LayoutMetrics.visWidth, alignment: .center)
            Text(formattedUpdated(repo.updatedAt))
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.textMuted)
                .lineLimit(1)
                .frame(width: LayoutMetrics.updatedWidth, alignment: .leading)
            rowActions(cloned: cloned, conflict: conflict)
                .frame(width: LayoutMetrics.actionsWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(SelectionBackground(selected: selected))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border.opacity(0.75))
                .frame(height: 1)
                .padding(.leading, LayoutMetrics.rowDividerLeadingInset) // keep icon gutter visually clean
                .padding(.trailing, 12)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedRepo = repo.id }
        .padding(.horizontal, 4)
    }

    // MARK: Row actions

    @ViewBuilder
    private func rowActions(cloned: Bool, conflict: RepoFolderConflict?) -> some View {
        HStack(spacing: 7) {
            if cloned {
                openMenu
                iconButton("arrow.down", "Pull (git pull)") {
                    Task { await model.repoActionCoordinator.pull(repo, in: account) }
                }
                iconButton("pencil", "Commit all changes…") {
                    commitTarget = RepoActionTarget(repo: repo, account: account)
                }
                iconButton("arrow.up", "Push (git push)") {
                    pushTarget = RepoActionTarget(repo: repo, account: account)
                }
                iconButton("trash", "Move local folder to Trash (recoverable)",
                           tint: theme.error, fill: theme.errorSubtle) {
                    deleteTarget = RepoActionTarget(repo: repo, account: account)
                }
            } else if let conflict {
                disabledIconChip("exclamationmark.triangle.fill",
                                 conflict.shortHelp,
                                 tint: theme.warning,
                                 fill: theme.warningSubtle)
            } else {
                iconButton("square.and.arrow.down", "Clone into the account folder") {
                    Task { await model.repoActionCoordinator.clone(repo, in: account) }
                }
            }
        }
        // A pull/push/commit/clone is already running for this repo — block a second
        // one rather than let two git processes collide on the same local folder.
        .disabled(model.repoActionCoordinator.isRepoActionBusy(repo))
    }

    // MARK: Open menu

    private var openMenu: some View {
        ActionPopoverButton(systemName: "folder", help: "Open…") { isPresented in
            VStack(alignment: .leading, spacing: 4) {
                openPopoverButton("Finder", systemImage: "folder") {
                    isPresented.wrappedValue = false
                    model.repoActionCoordinator.openLocalFolder(repo, in: account)
                }

                openPopoverButton("GitHub", systemImage: "globe") {
                    isPresented.wrappedValue = false
                    model.repoActionCoordinator.openGitHubRepo(repo)
                }

                if preferredEditor == .none {
                    openPopoverDisabledRow("Editor not configured",
                                           systemImage: "chevron.left.forwardslash.chevron.right")
                } else {
                    openPopoverButton(preferredEditor.displayName(customAppName: customEditorName),
                                      systemImage: "chevron.left.forwardslash.chevron.right") {
                        isPresented.wrappedValue = false
                        Task {
                            await model.repoActionCoordinator.openInEditor(repo,
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
                            await model.repoActionCoordinator.openInTerminal(repo,
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

    private func openPopoverButton(_ title: String,
                                   systemImage: String,
                                   action: @escaping () -> Void) -> some View {
        OpenPopoverRow(title: title, systemImage: systemImage, action: action)
    }

    private func openPopoverDisabledRow(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .opacity(0.75)
    }

    private func iconButton(_ systemName: String, _ help: String,
                            tint: Color? = nil, fill: Color? = nil,
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

    // MARK: Icons and badges

    private func repoIcon(cloned: Bool, conflict: RepoFolderConflict?) -> String {
        if cloned { return "internaldrive.fill" }
        if conflict != nil { return "exclamationmark.triangle.fill" }
        return "cloud"
    }

    private func repoIconColor(cloned: Bool,
                               attention: Bool,
                               conflict: RepoFolderConflict?) -> Color {
        if conflict != nil { return theme.warning }
        if cloned { return attention ? theme.warning : theme.accent }
        return theme.textMuted
    }

    /// A repo is "shared" when its owner is not the selected account — i.e. you
    /// were added as a collaborator. Own repos return false (no badge).
    private func isShared(_ repo: Repo) -> Bool {
        repo.owner.caseInsensitiveCompare(account.alias) != .orderedSame
    }

    /// Grey two-people icon marking a repo shared with you by another account.
    /// The owner login lives in the tooltip to keep the row uncluttered.
    private func sharedBadge(_ owner: String) -> some View {
        Image(systemName: "person.2.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.textMuted)
            .tooltip("Shared by \(owner) — you're a collaborator")
            .accessibilityLabel("Shared by \(owner)")
    }

    private func folderConflictBadge(_ conflict: RepoFolderConflict) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(theme.warning)
            .tooltip(conflict.shortHelp)
            .accessibilityLabel(conflict.shortHelp)
    }

    /// Visibility as a glanceable icon: amber lock = private, green globe =
    /// public, grey building = internal. The word stays in the tooltip.
    @ViewBuilder
    private func visBadge(_ raw: String) -> some View {
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
    private func statusBadges(_ status: RepoStatus, repo: Repo, account: Account) -> some View {
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
                               conflict: RepoFolderConflict?) -> String {
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

    /// Parses the ISO-8601 timestamps returned by `gh` (e.g. 2026-06-02T16:40:31Z).
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Locale-aware date+time display.
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
}
