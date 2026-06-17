import SwiftUI

/// The clickable change indicator in a repo row: an amber pencil pill that shows
/// the changed-file count and, on click, a lightweight grouped summary popover.
/// Deliberately not a diff viewer — just "what changed", grouped by status.
struct ChangeSummaryButton: View {
    let repo: Repo
    let account: Account
    let count: Int
    @EnvironmentObject private var repoActionCoordinator: RepoActionCoordinator
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 2) {
                Image(systemName: "pencil").font(.system(size: 9, weight: .bold))
                Text("\(count)").font(.system(size: 10, weight: .bold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .black))
                    .opacity(0.65)
            }
            .foregroundStyle(theme.warning)
            .padding(.vertical, 1).padding(.horizontal, 5)
            .background(theme.warningSubtle)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tooltip("\(count) changed file\(count == 1 ? "" : "s") — click for a summary")
        .accessibilityLabel("\(count) changed files. Show summary.")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ChangeSummaryContent(repo: repo, account: account)
                .gitNestEnvironment(model)
        }
    }
}

/// Contents of the change-summary popover. Loads the detailed file list on demand
/// when it appears, so the interval scan stays cheap (counts only).
struct ChangeSummaryContent: View {
    let repo: Repo
    let account: Account
    @EnvironmentObject private var repoActionCoordinator: RepoActionCoordinator
    @Environment(\.theme) private var theme
    @State private var phase: Phase = .loading

    /// Cap the scroll area; larger change sets scroll inside it.
    private static let maxListHeight: CGFloat = 340
    /// Keep each group a quick summary, not an exhaustive listing.
    private static let maxFilesPerGroup = 12

    // Approximate row metrics used to size the scroll area from the data, so the
    // popover never collapses (a ScrollView has no natural height of its own).
    private static let rowHeight: CGFloat = 18
    private static let headingHeight: CGFloat = 20
    private static let groupSpacing: CGFloat = 12

    enum Phase {
        case loading
        case empty
        case failed(String)
        case loaded([GitChangeGroup])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Changes in \(repo.name)")
                .font(Theme.title(14))
                .foregroundStyle(theme.text)
            content
        }
        .padding(16)
        .frame(width: 320)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading changes…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .empty:
            Label("No changes — the working tree is clean.", systemImage: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(theme.success)
                .fixedSize(horizontal: false, vertical: true)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn't read changes", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.error)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .loaded(let groups):
            loadedList(groups)
        }
    }

    private func loadedList(_ groups: [GitChangeGroup]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.groupSpacing) {
                ForEach(groups) { groupView($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Concrete height derived from the rows we'll draw, capped so big change
        // sets scroll. A ScrollView with only a max height collapses in a popover.
        .frame(height: min(estimatedHeight(groups), Self.maxListHeight))
    }

    private func estimatedHeight(_ groups: [GitChangeGroup]) -> CGFloat {
        var height: CGFloat = 0
        for (index, group) in groups.enumerated() {
            if index > 0 { height += Self.groupSpacing }
            height += Self.headingHeight
            let shown = min(group.files.count, Self.maxFilesPerGroup)
            height += CGFloat(shown) * Self.rowHeight
            if group.files.count > shown { height += Self.rowHeight }   // "+N more"
        }
        return height
    }

    private func groupView(_ group: GitChangeGroup) -> some View {
        let shown = Array(group.files.prefix(Self.maxFilesPerGroup))
        let overflow = group.files.count - shown.count
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(group.title) (\(group.files.count))")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color(for: group.status))
            ForEach(shown) { file in
                Text(line(for: file))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if overflow > 0 {
                Text("+ \(overflow) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(for file: GitFileChange) -> String {
        if let original = file.originalPath {
            return "\(original) → \(file.path)"
        }
        return file.path
    }

    private func color(for status: GitChangeStatus) -> Color {
        switch status {
        case .modified:   return theme.warning
        case .added:      return theme.success
        case .deleted:    return theme.error
        case .renamed:    return theme.accent
        case .untracked:  return theme.blue
        case .conflicted: return theme.pink
        case .other:      return theme.teal
        }
    }

    private func load() async {
        phase = .loading
        switch await repoActionCoordinator.changedFiles(for: repo, in: account) {
        case .success(let files):
            phase = files.isEmpty ? .empty : .loaded(GitChanges.grouped(files))
        case .failure(let error):
            phase = .failed(error.message)
        }
    }
}
