import SwiftUI

/// Lightweight, read-only commit-history popover for a cloned repo. Loads recent
/// commits on demand when it appears, mirroring `ChangeSummaryContent` — kept out
/// of the interval scan, and deliberately not a full log viewer (just the latest
/// commits, subject + author + relative date).
struct CommitHistoryContent: View {
    let repo: Repo
    let account: Account
    @EnvironmentObject private var repoActionCoordinator: RepoActionCoordinator
    @Environment(\.theme) private var theme
    @State private var phase: Phase = .loading

    /// Cap the scroll area; longer histories scroll inside it.
    private static let maxListHeight: CGFloat = 340
    // Approximate row metrics used to size the scroll area from the data, so the
    // popover never collapses (a ScrollView has no natural height of its own).
    private static let rowHeight: CGFloat = 38
    private static let rowSpacing: CGFloat = 10

    enum Phase {
        case loading
        case empty
        case failed(String)
        case loaded([GitCommit])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent commits in \(repo.name)")
                .font(Theme.title(14))
                .foregroundStyle(theme.text)
            content
        }
        .padding(16)
        .frame(width: 360)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading history…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .empty:
            Label("No commits yet.", systemImage: "clock")
                .font(.system(size: 12))
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn't read history", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.error)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .loaded(let commits):
            loadedList(commits)
        }
    }

    private func loadedList(_ commits: [GitCommit]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(commits) { commitRow($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Concrete height derived from the rows we'll draw, capped so long histories
        // scroll. A ScrollView with only a max height collapses in a popover.
        .frame(height: min(estimatedHeight(commits), Self.maxListHeight))
    }

    private func estimatedHeight(_ commits: [GitCommit]) -> CGFloat {
        let n = CGFloat(commits.count)
        return n * Self.rowHeight + max(0, n - 1) * Self.rowSpacing
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(commit.shortHash)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .textSelection(.enabled)
                Text(commit.subject)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !commitMeta(commit).isEmpty {
                Text(commitMeta(commit))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitMeta(_ commit: GitCommit) -> String {
        [commit.author, commit.relativeDate]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func load() async {
        phase = .loading
        switch await repoActionCoordinator.recentCommits(for: repo, in: account) {
        case .success(let commits):
            phase = commits.isEmpty ? .empty : .loaded(commits)
        case .failure(let error):
            phase = .failed(error.displayMessage)
        }
    }
}
